//
//  NotificationHandler.swift
//  hybrid
//
//  Created by alastair.coote on 05/10/2016.
//  Copyright © 2016 Alastair Coote. All rights reserved.
//

import Foundation
import UserNotifications
import JavaScriptCore
import PromiseKit

class PendingNotificationActions {
    private static let groupDefaults = NSUserDefaults(suiteName: "group.gdnmobilelab.hybrid")!
    
    private static func setValue(name:String, val:AnyObject?) {
        if val == nil {
            groupDefaults.removeObjectForKey(name)
        } else {
            groupDefaults.setObject(val!, forKey: name)
        }
        
    }
    
    private static func getValue(name:String) -> AnyObject? {
        return groupDefaults.objectForKey(name)
    }
    
    static var closeNotification:Bool? {
        get {
            return getValue("pendingNotifications.closeNotification") as? Bool
        }
        
        set(val) {
            setValue("pendingNotifications.closeNotification", val: val)
        }
    }
    
    
    static func reset() {
        self.closeNotification = nil
    }
}

struct ActiveNotificationViews {
    var video:NotificationVideo?
}

class NotificationHandler {
    static func processAction(response:UNNotificationResponse, userInfo:[NSObject: AnyObject], activeViews: ActiveNotificationViews) -> Promise<Void> {
       
        let notificationData = userInfo["originalNotificationOptions"]!
        
        let notification = Notification(title: userInfo["originalTitle"] as! String)
        notification.body = notificationData["body"] as? String
        notification.tag = notificationData["tag"] as? String
        notification.actions = notificationData["actions"] as? [AnyObject]
        notification.icon = notificationData["icon"] as? String
        notification.image = notificationData["image"]
        notification.data = notificationData["data"]
        notification.video = activeViews.video
        
        let workerScope = userInfo["serviceWorkerScope"] as! String
        
        var action = ""
        
        if response.actionIdentifier != UNNotificationDefaultActionIdentifier {
            action = response.actionIdentifier
        }
        
        return ServiceWorkerManager.getServiceWorkerForURL(NSURL(string:workerScope)!)
        .then { sw in
            
            var eventType = "notificationclick"
            
            if response.actionIdentifier == "com.apple.UNNotificationDismissActionIdentifier" {
                eventType = "notificationclose"
            }
            let notificationEvent = NotificationEvent(type: eventType, notification: notification, action: action)
            
            return sw!.dispatchExtendableEvent(notificationEvent)
            .then { _ in
                // disregard result - we don't need it
                return Promise<Void>()
            }
            
        }
        

    
    }
}
