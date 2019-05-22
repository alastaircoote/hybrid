//
//  ServiceWorkerGlobalScope.swift
//  hybrid
//
//  Created by alastair.coote on 20/11/2016.
//  Copyright © 2016 Alastair Coote. All rights reserved.
//

import Foundation
import JavaScriptCore

@objc protocol ServiceWorkerGlobalScopeExports: JSExport {
    func skipWaiting()
}

/// A work in progress. In time I want to move all of the custom classes into here.
@objc class ServiceWorkerGlobalScope: NSObject, ServiceWorkerGlobalScopeExports {
    
    @objc var skipWaitingStatus = false
    @objc var jsContext:JSContext
    
    @objc init(context:JSContext) {
        self.jsContext = context
        super.init()
        self.applySelfToGlobal()
    }
    
    func skipWaiting() {
        self.skipWaitingStatus = true
    }
    
    fileprivate var skipWaitingAnyObject:AnyObject {
        get {
            let convention: @convention(block) () -> Void = self.skipWaiting
            return unsafeBitCast(convention, to: AnyObject.self)
        }
    }
    
    
    /// Go through all of our global scope objects, apply to "self" *and* to the
    /// global scope of the worker. Using Object.keys() feels like of hacky, but it works.
    @objc func applySelfToGlobal() {
        
        self.jsContext.setObject(ServiceWorkerGlobalScope.self, forKeyedSubscript: "ServiceWorkerGlobalScope" as (NSCopying & NSObjectProtocol)!)
        self.jsContext.setObject(self, forKeyedSubscript: "self" as (NSCopying & NSObjectProtocol)!)
        
        // Slightly confusing, but we now grab the JSValue version of this class, so that we can apply
        // custom keys to it.
        
        let jsSelf = self.jsContext.objectForKeyedSubscript("self")
        
        let toApply:[String:AnyObject] = [
            "MessagePort": MessagePort.self,
            "ServiceWorkerRegistration": ServiceWorkerRegistration.self,
            "PushManager": PushManager.self,
            "MessageChannel": MessageChannel.self,
            "Client": WindowClient.self,
            "ExtendableMessageEvent": ExtendableMessageEvent.self,
            "OffscreenCanvas": OffscreenCanvas.self,
            "OffscreenCanvasRenderingContext2D": OffscreenCanvasRenderingContext2D.self,
            "ImageBitmap": ImageBitmap.self,
            "ExtendableEvent": ExtendableEvent.self,
            "Notification": Notification.self,
            "PushMessageData": PushMessageData.self,
            "createImageBitmap": ImageBitmap.createImageBitmap
        ]
        
        for (key, val) in toApply {
            self.jsContext.setObject(val, forKeyedSubscript: key as (NSCopying & NSObjectProtocol)!)
            jsSelf?.setObject(val, forKeyedSubscript: key as (NSCopying & NSObjectProtocol)!)
        }
        
    }

}
