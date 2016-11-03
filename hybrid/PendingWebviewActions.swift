//
//  PendingWebviewActions.swift
//  hybrid
//
//  Created by alastair.coote on 02/11/2016.
//  Copyright © 2016 Alastair Coote. All rights reserved.
//

import Foundation

class PendingWebviewActions {
    
    // Our notification extension cannot communicate directly with our webviews, so when a notification
    // action triggers a webview action we store it. Then pick it back up when the app launches.
    
    static func getAll() -> [WebviewClientEvent] {
        NSKeyedUnarchiver.setClass(WebviewClientEvent.self, forClassName: "WebviewClientEvent")
        NSKeyedUnarchiver.setClass(WebviewRecord.self, forClassName: "WebviewRecord")
        
        if let storedData = SharedSettings.storage.dataForKey("pending_webview_actions") {
            let stored = NSKeyedUnarchiver.unarchiveObjectWithData(storedData) as! [WebviewClientEvent]
            
            return stored
        }
        
        return []

    }
    
    static func set(clients: [WebviewClientEvent]) {
        NSKeyedArchiver.setClassName("WebviewClientEvent", forClass: WebviewClientEvent.self)
        NSKeyedArchiver.setClassName("WebviewRecord", forClass: WebviewRecord.self)
        SharedSettings.storage.setObject(NSKeyedArchiver.archivedDataWithRootObject(clients), forKey: "pending_webview_actions")
    }
    
    static func add(event:WebviewClientEvent) {
        var all = getAll()
        
        all.append(event)
        
        set(all)
    }
    
    static func clear() {
        SharedSettings.storage.removeObjectForKey("pending_webview_actions")
    }
}
