//
//  ServiceWorkerManager.swift
//  hybrid
//
//  Created by alastair.coote on 14/07/2016.
//  Copyright © 2016 Alastair Coote. All rights reserved.
//

import Foundation
import PromiseKit
import FMDB
import JavaScriptCore
import EmitterKit


/// The various states a Service Worker can exist in. As outlined in: https://developer.mozilla.org/en-US/docs/Web/API/ServiceWorker/state
///
/// - Installing: The worker is currently in the process of installing
/// - Installed: The worker has successfully installed and is awaiting activation
/// - Activating: The worker is currently in the process of activating
/// - Activated: The worker is activated and ready to receive events and messages
/// - Redundant: The worker has either failed to install or has been superseded by a new version of the worker.
enum ServiceWorkerInstallState: Int {
    case Installing
    case Installed
    case Activating
    case Activated
    case Redundant
}


/// Used in service worker events. We can't send the worker itself as a payload as
/// we send this into our HybridWebView, where we can only transfer primitives. So we
/// pass this around and use ServiceWorkerInstance.getById() to grab again when
/// the HybridWebView sends a response
class ServiceWorkerMatch {
    
    
    /// Convert this into an object containing string/int primitives that can be
    /// JSON encoded successfully. If you don't use this, JSONSerialization will fail.
    ///
    /// - Returns: AnyObject that is serializable.
    func toSerializableObject() -> [String:AnyObject] {
        return [
            "instanceId": self.instanceId,
            "installState": self.installState.rawValue,
            "url": self.url.absoluteString!,
            "scope": self.scope.absoluteString!
        ]
    }
    
    var instanceId: Int!
    var installState: ServiceWorkerInstallState!
    var url:NSURL!
    var scope:NSURL!
    
    init(instanceId:Int, url:NSURL, installState: ServiceWorkerInstallState, scope: NSURL) {
        self.instanceId = instanceId
        self.installState = installState
        self.url = url
        self.scope = scope
    }

}


/// This error is thrown when we have assumed that a service worker exists when it actually does not.
class ServiceWorkerDoesNotExistError : ErrorType {}


/// Service Workers must be served over HTTPS. This will be thrown when you attempt to load
/// a service worker over HTTP.
class ServiceWorkerNotHTTPSError : ErrorType {}


/// The ServiceWorkerManager is responsible for a few things. Firstly, for the worker lifecycle itself -
/// installing, updating, etc. etc.
class ServiceWorkerManager {
    
    /// Just a static string for us to ensure we are using the right event
    /// name when attaching listeners
    static let STATUS_CHANGE_EVENT = "service-worker-status-change"
    
    /// EmitterKit event handler that is used whenever a service worker state changes
    static let events = Event<ServiceWorkerMatch>()
    
    
    /// A map of current, in-use service workers. We use this to ensure that we don't
    /// ever create more than one instance of a worker.
    static var currentlyActiveServiceWorkers = [Int: ServiceWorkerInstance]()
    
    
    /// Empty our map of service workers. This is (currently) only used in tests, to
    /// clear out existing workers.
    static func clearActiveServiceWorkers() {
        self.currentlyActiveServiceWorkers.removeAll(keepCapacity: false)
    }
    
    
    /// Send a HEAD request to the URL specified and turn the resulting
    /// Last-Modified header into an NSDate
    ///
    /// - Parameter url: URL to fetch
    /// - Returns: NSDate if the Last-Modified header exists, nil if it doesn't
    static private func getLastModified(url:NSURL) -> Promise<NSDate?> {
        
        let request = FetchRequest(url: url.absoluteString!, options: [
            "method": "HEAD"
        ])
        
        return GlobalFetch.fetchRequest(request)
        .then { response -> Promise<NSDate?> in
            let lastMod = response.headers.get("last-modified")
            
            var date:NSDate? = nil
            
            if lastMod != nil {
                date = Util.HTTPDateToNSDate(lastMod!)
            }
            
            return Promise<NSDate?>(date)
            
        }
        
    }
    
    
    /// Fetch a stub of the newest worker for a given URL, with following order: activated,
    /// activating, installed, installing
    ///
    /// - Parameter urlOfWorker: the URL to query in the database
    /// - Returns: a ServiceWorkerStub, if the worker exists. The stub just contains metadata, rather than a full instance.
    /// - Throws: If the database connection fails, will throw an error.
    private static func getNewestWorker(urlOfWorker:NSURL) throws -> ServiceWorkerStub? {
        
        var stub:ServiceWorkerStub? = nil
        
        try Db.mainDatabase.inDatabase({ (db) in
            let result = try db.executeQuery("SELECT * FROM service_workers WHERE url = ? AND NOT install_state = ? ORDER BY install_state DESC LIMIT 1", values: [urlOfWorker, ServiceWorkerInstallState.Redundant.rawValue])
            
            if result.next() == false {
                result.close()
                return
            }
            
            stub = ServiceWorkerStub(
                instanceId: Int(result.intForColumn("instance_id")),
                installState: ServiceWorkerInstallState(rawValue: Int(result.intForColumn("install_state")))!,
                lastChecked: Int(result.intForColumn("last_checked")),
                scope: NSURL(string: result.stringForColumn("scope"))!,
                jsHash: Util.sha256String(String(data: result.dataForColumn("contents"), encoding: NSUTF8StringEncoding)!)
            )

            result.close()
        })
        
        return stub
        
    }
    
    
    /// Update or register a service worker from a remote URL. The bulk of what the manager is responsible for.
    /// Emits events on ServiceWorkerManager.events when a worker state changes.
    ///
    /// Follows (loosely!) the spec outlined here: http://www.w3.org/TR/service-workers/#service-worker-registration-update-method
    ///
    /// - Parameters:
    ///   - urlOfServiceWorker: The URL for the JavaScript file containing the service worker
    ///   - scope: If registering a new worker, the scope to register under. Optional, as when updating we use the existing scope.
    ///   - forceCheck: By default, register() only checks the remote URL once every 24 hours. But update() forces it.
    /// - Returns: A promise containing the instance ID of the newly installed worker.
    static func update(urlOfServiceWorker:NSURL, scope:NSURL? = nil, forceCheck:Bool = false) -> Promise<Int> {
        
        return Promise<Void>()
        .then { () -> Promise<Int> in
            
            let newest = try self.getNewestWorker(urlOfServiceWorker)
            
            // Get the newest worker. Following spec here: http://www.w3.org/TR/service-workers/#get-newest-worker-algorithm
            
            // shorter way of saying it is grab workers in following order: activated, activating, installed, installing
            // so we use SQL to just select the first one, ordered by install state.
            
//            var existingJS:String?
//            var scopeToUse = scope
//            var lastChecked:Int = -1
//            var serviceWorkerId:Int?
//            var currentInstallState:ServiceWorkerInstallState?
//            
//            try Db.mainDatabase.inDatabase({ (db) in
//                let result = try db.executeQuery("SELECT * FROM service_workers WHERE url = ? AND NOT install_state = ? ORDER BY install_state DESC LIMIT 1", values: [urlOfServiceWorker, ServiceWorkerInstallState.Redundant.rawValue])
//                
//                if result.next() == false {
//                    
//                    // If there's no existing service worker record, we must update
//                    log.debug("No existing version for worker " + urlOfServiceWorker.absoluteString!)
//                    result.close()
//                    return
//                }
//                
//                existingJS = String(data: result.dataForColumn("contents"), encoding: NSUTF8StringEncoding)
//                serviceWorkerId = Int(result.intForColumn("instance_id"))
//                lastChecked = Int(result.intForColumn("last_checked"))
//                currentInstallState = ServiceWorkerInstallState(rawValue: Int(result.intForColumn("install_state")))
//                
//                // Confusion caused by combining update and register. Should separate at some point.
//                
//                if scopeToUse == nil {
//                    scopeToUse = NSURL(string: result.stringForColumn("scope"))
//                }
//                result.close()
//            })
            
            // If our worker is installing or activating, then we return the existing one rather than start a new check loop
            
            if let swState = newest?.installState {
                if swState != ServiceWorkerInstallState.Activated && swState != ServiceWorkerInstallState.Redundant {
                    log.info("Worker currently in install or activate state - returning existing instance")
                    return Promise<Int>(newest!.instanceId)
                }
            }
            
            // Service Worker API (in Chrome at least?) doesn't try to download new JS if it's already
            // checked within the last 24 hours. So we want to mirror that same behaviour.
            
            let timeDiff = 60 * 60 * 24 // 24 hours in seconds
            
            let rightNow = Int(NSDate().timeIntervalSince1970)
            
            if newest != nil && newest!.lastChecked + timeDiff > rightNow && forceCheck == false {
                // We've checked within the last 24 hours. So just return the existing worker
                log.info("Existing worker has been checked within 24 hours. Returning")
                
                return Promise<Int>(newest!.instanceId)
                
            }
     
            return GlobalFetch.fetch(urlOfServiceWorker.absoluteString!)
            .then { response -> Promise<Int> in
                
                let newJS = String(data: response.data!, encoding: NSUTF8StringEncoding)!
                let newJSHash = Util.sha256String(newJS)
                
                if newest?.jsHash == newJSHash {
                    // No new code, so just return the ID of the existing worker.
                    log.info("Checked for update to " + urlOfServiceWorker.absoluteString! + ", but no change.")
                    
                    try Db.mainDatabase.inTransaction { db in
                        // Update the DB with our new last checked time
                        try db.executeUpdate("UPDATE service_workers SET last_checked = ? WHERE instance_id = ?", values: [rightNow, newest!.instanceId])
                    }

                    return Promise<Int>(newest!.instanceId)
                }
                
                log.info("Installing new service worker from: " + urlOfServiceWorker.absoluteString!)
                
                let scopeToUse = scope != nil ? scope! : newest!.scope
                
                return self.insertServiceWorkerIntoDB(
                    urlOfServiceWorker,
                    scope: scopeToUse,
                    lastChecked: rightNow,
                    js: response.data!
                ).then { id in
                    
                    // This happens async, so don't wrap up in the promise
                    self.installServiceWorker(id)
                    return Promise<Int>(id)
                }
                
            }
            
        }

    }
    
    static func getAllServiceWorkersForURL(pageURL:NSURL) -> Promise<[ServiceWorkerMatch]> {
        return Promise<Void>()
        .then {
            var workerRecords:[ServiceWorkerMatch] = [];
            
            try Db.mainDatabase.inDatabase({ (db) in
                
                let selectScopeQuery = "SELECT scope FROM service_workers WHERE ? LIKE (scope || '%') ORDER BY length(scope) DESC LIMIT 1"
                
                let allWorkersResultSet = try db.executeQuery("SELECT instance_id, install_state, url, scope FROM service_workers WHERE scope = (" + selectScopeQuery + ")", values: [pageURL.absoluteString!])
                
                
                while allWorkersResultSet.next() {
                    let instanceId = Int(allWorkersResultSet.intForColumn("instance_id"))
                    let installState = ServiceWorkerInstallState(rawValue: Int(allWorkersResultSet.intForColumn("install_state")))!
                    let url = NSURL(string: allWorkersResultSet.stringForColumn("url"))!
                    let scope = NSURL(string:allWorkersResultSet.stringForColumn("scope"))!
                    workerRecords.append(ServiceWorkerMatch(instanceId: instanceId, url: url, installState: installState, scope: scope))
                }
                
                allWorkersResultSet.close()
                
            })
            
            return Promise<[ServiceWorkerMatch]>(workerRecords)

        }
    }
    
    static func insertServiceWorkerIntoDB(serviceWorkerURL:NSURL, scope: NSURL, lastChecked:Int, js:NSData, installState:ServiceWorkerInstallState = ServiceWorkerInstallState.Installing) -> Promise<Int> {
        
        
        
        return Promise<Void>()
        .then {
            
            if serviceWorkerURL.host != "localhost" && (serviceWorkerURL.scheme == "http" || scope.scheme == "http") {
                log.error("Both scope and service worker URL must be under HTTPS")
                throw ServiceWorkerNotHTTPSError()
            }
            
            var newId:Int64 = -1
            
            try Db.mainDatabase.inTransaction({ (db) in
                try db.executeUpdate("INSERT INTO service_workers (url, scope, last_checked, contents, install_state) VALUES (?,?,?,?,?)", values: [serviceWorkerURL.absoluteString!, scope.absoluteString!, lastChecked, js, installState.rawValue ] as [AnyObject])
                
                newId = db.lastInsertRowId()
            })
            
            log.debug("Inserted service worker into DB for URL: " + serviceWorkerURL.absoluteString! + " with installation state " + String(installState))
            
            let match = ServiceWorkerMatch(instanceId: Int(newId), url: serviceWorkerURL, installState: installState, scope: scope)
            
            self.events.emit(STATUS_CHANGE_EVENT, match)
            
            return Promise<Int>(Int(newId))
        }
       
    }
    
    private static func updateServiceWorkerInstallState(id: Int, state:ServiceWorkerInstallState, updateDatabase:Bool = true) throws {
        
        let idAsNSNumber = NSNumber(longLong: Int64(id))
        
        if updateDatabase == true {
            try Db.mainDatabase.inTransaction({ (db:FMDatabase) in
                
                
                
                try db.executeUpdate("UPDATE service_workers SET install_state = ? WHERE instance_id = ?", values: [state.rawValue, idAsNSNumber] as [AnyObject])
                
                if db.changes() == 0 {
                    throw ServiceWorkerDoesNotExistError()
                }
            })
        }
        
        var url:NSURL? = nil
        var scope:NSURL? = nil
        
        try Db.mainDatabase.inDatabase { (db) in
            
            let set = try db.executeQuery("SELECT url, scope FROM service_workers WHERE instance_id = ?", values: [idAsNSNumber])
            
            if set.next() == false {
                throw ServiceWorkerDoesNotExistError()
            }
            
            url = NSURL(string: set.stringForColumn("url"))
            scope = NSURL(string: set.stringForColumn("scope"))
            
            set.close()
        }
        
        
        
        if self.currentlyActiveServiceWorkers[id] != nil {
            self.currentlyActiveServiceWorkers[id]!.installState = state
        }
        
        let matchToDispatch = ServiceWorkerMatch(instanceId: id, url: url!, installState: state, scope: scope!)
        
        self.events.emit(STATUS_CHANGE_EVENT, matchToDispatch)
    }
    
    static func activateServiceWorker(swInstance:ServiceWorkerInstance) -> Promise<Void> {
        return Promise<Void>()
        .then {
            try self.updateServiceWorkerInstallState(swInstance.instanceId, state: ServiceWorkerInstallState.Activating)
            
            return swInstance.dispatchExtendableEvent(ExtendableEvent(type: "activate"))
            .then { _ -> Void in
                
                // Activate was successful.
                // Now set all other workers for this scope to "redundant". Need to do a select
                // so that we can dispatch these same events to flag workers as redundant.
                
                // TODO: cleanup. Just delete the rows?
                
                var idsToInvalidate = [Int]()
                let idAsNSNumber = NSNumber(longLong: Int64(swInstance.instanceId))
                
                try Db.mainDatabase.inTransaction({ (db) in
                    let workersToMakeRedundant = try db.executeQuery("SELECT instance_id FROM service_workers WHERE url = ? AND NOT instance_id = ?", values: [swInstance.url.absoluteString!, idAsNSNumber])
                    
                    while workersToMakeRedundant.next() {
                        idsToInvalidate.append(Int(workersToMakeRedundant.intForColumn("instance_id")))
                    }
                    
                    workersToMakeRedundant.close()
                    
                    // we're running these queries manually inside a transaction, so we know they all
                    // ran successfully.
                    
                    try db.executeUpdate("UPDATE service_workers SET install_state = ? WHERE instance_id = ?", values: [ServiceWorkerInstallState.Activated.rawValue, idAsNSNumber] as [AnyObject])
                    
                    // FMDB doesn't support arrays, so we have to manually create our query string with the right number of ?
                    // characters for the number of values we're going to input
                    
                    let placeholders = idsToInvalidate.map({ _ in
                        return "?"
                    }).joinWithSeparator(",")
                    
                    var params = [AnyObject]()
                    
                    params.append(ServiceWorkerInstallState.Redundant.rawValue)
                    
                    for id in idsToInvalidate {
                        params.append(id)
                    }
                    
        
                    try db.executeUpdate("UPDATE service_workers SET install_state = ? WHERE instance_id IN (" + placeholders + ")", values: params)

                })
                
                // now that we've committed the transaction, dispatch events
                
                try self.updateServiceWorkerInstallState(swInstance.instanceId, state: ServiceWorkerInstallState.Activated, updateDatabase: false)
                
                for oldWorkerId in idsToInvalidate {
                    try self.updateServiceWorkerInstallState(oldWorkerId, state: ServiceWorkerInstallState.Redundant, updateDatabase: false)
                }
            }
            
        }
    }
    
    
    static func installServiceWorker(id:Int) -> Promise<ServiceWorkerInstallState> {
        
        // Service workers run "install" events, and if successful, "activate" events.
        // If either of these fail, it's considered redundant and invalid. So that's
        // what we'll do!
        
        return ServiceWorkerInstance.getById(id)
        .then { (swInstance) -> Promise<ServiceWorkerInstallState> in
            return swInstance!.dispatchExtendableEvent(ExtendableEvent(type: "install"))
            .then { (_) -> Promise<ServiceWorkerInstallState> in
                
                try self.updateServiceWorkerInstallState(id, state: ServiceWorkerInstallState.Installed)
                
                let runActivate = swInstance!.executeJS("hybrid.__getSkippedWaitingStatus()").toBool()
                
                if runActivate == true {
                    log.info("Service worker " + swInstance!.url.absoluteString! + " called skipWaiting()")
                }
                
                if runActivate == false {
                    return Promise<ServiceWorkerInstallState>(ServiceWorkerInstallState.Installed)
                } else {
                    return self.activateServiceWorker(swInstance!)
                    .then { _ in
                        return Promise<ServiceWorkerInstallState>(ServiceWorkerInstallState.Activated)
                    }
                }
    
            }
            .recover { error -> Promise<ServiceWorkerInstallState> in
                
                // If an error occurred in either the installation or optional activation step,
                // mark the worker as redundant.
                log.error("Error during installation: " + String(error))
                try self.updateServiceWorkerInstallState(id, state: ServiceWorkerInstallState.Redundant)
                
                return Promise<ServiceWorkerInstallState>(ServiceWorkerInstallState.Redundant)
            }
           
        }
        
    }
    
    
    
    static func cycleThroughEligibleWorkers(workerIds:[Int]) -> Promise<ServiceWorkerInstance?> {
        if (workerIds.count == 0) {
            return Promise<ServiceWorkerInstance?>(nil)
        }
        
        return ServiceWorkerInstance.getById(workerIds.first!)
        .then { (sw) -> Promise<ServiceWorkerInstance?> in
            log.debug("Eligible service worker with install state: " + String(sw!.installState))
            if (sw!.installState == ServiceWorkerInstallState.Installed) {
                return self.activateServiceWorker(sw!)
                .then {
                    return Promise<ServiceWorkerInstance?>(sw)
                }
            }
            
            return Promise<ServiceWorkerInstance?>(sw)
        }
        .then { sw in
            if sw?.installState == ServiceWorkerInstallState.Activated {
                return Promise<ServiceWorkerInstance?>(sw!)
            }
            
            return cycleThroughEligibleWorkers(Array(workerIds.dropFirst()))
        }
    }
    
    static func getServiceWorkerForURL(url:NSURL) -> Promise<ServiceWorkerInstance?> {
        
        for (_, sw) in self.currentlyActiveServiceWorkers {
            
            // If we have an active service worker serving this scope, then immediately
            // return it.
            
            if sw.scopeContainsURL(url) == true {
                return Promise<ServiceWorkerInstance?>(sw)
            }
        }
        
        // If we have no active service worker, we need to find if one matches. Also, if it
        // has a status of Installed, we need to activate it. BUT if that activation fails
        // we need to use an older, installed worker.
        
        return Promise<Void>()
        .then { () -> Promise<[Int]> in
            var workerIds = [Int]()
            
            try Db.mainDatabase.inDatabase({ (db) in
                // Let's first make sure we're selecting with the most specific scope
                
                let selectScopeQuery = "SELECT scope FROM service_workers WHERE ? LIKE (scope || '%') OR ? = scope ORDER BY length(scope) DESC LIMIT 1"
                
                let applicableWorkerResultSet = try db.executeQuery("SELECT instance_id FROM service_workers WHERE scope = (" + selectScopeQuery  + ") AND (install_state == ? OR install_state = ?) ORDER BY instance_id DESC", values: [url.absoluteString!, url.absoluteString!, ServiceWorkerInstallState.Activated.rawValue, ServiceWorkerInstallState.Installed.rawValue])
               
                while applicableWorkerResultSet.next() {
                    workerIds.append(Int(applicableWorkerResultSet.intForColumn("instance_id")))
                }
                applicableWorkerResultSet.close()

            })
            
            return Promise<[Int]>(workerIds)
        }
        .then { ids in
            if (ids.count == 0) {
                return Promise<ServiceWorkerInstance?>(nil)
            }
            return self.cycleThroughEligibleWorkers(ids)
            .then { eligibleWorker in
//                if (eligibleWorker != nil) {
//                    self.currentlyActiveServiceWorkers.append(eligibleWorker!)
//                }
                return Promise<ServiceWorkerInstance?>(eligibleWorker)
            }
        }
        
        
        }
        
        
        
    }
