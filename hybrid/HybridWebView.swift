//
//  HybridWebView.swift
//  hybrid
//
//  Created by alastair.coote on 14/07/2016.
//  Copyright © 2016 Alastair Coote. All rights reserved.
//

import Foundation
import WebKit

class HybridWebview : WKWebView, WKNavigationDelegate {
    
    var console:ConsoleManager? = nil
    var messageChannelManager:MessageChannelManager? = nil
    
    init(frame: CGRect) {
        let config = WKWebViewConfiguration()
        config.userContentController = WKUserContentController()
        
        super.init(frame: frame, configuration: config)
        
        do {
            try self.injectJS(config.userContentController)

        } catch {
            // Don't really know what we'd do at this point
            log.error(String(error))
        }
        self.console = ConsoleManager(userController: config.userContentController, webView: self)
        self.messageChannelManager = MessageChannelManager(userController: config.userContentController, webView: self)
        
        self.navigationDelegate = self
    }
    
    func injectJS(userController: WKUserContentController) throws {
        let docStartPath = NSBundle.mainBundle().pathForResource("document-start", ofType: "js", inDirectory: "js-dist")!;
        let documentStartJS = try NSString(contentsOfFile: docStartPath, encoding: NSUTF8StringEncoding) as String;
     
        let userScript = WKUserScript(source: documentStartJS, injectionTime: .AtDocumentStart, forMainFrameOnly: true);
        userController.addUserScript(userScript)
    }
    
    func webView(webView: WKWebView, decidePolicyForNavigationAction navigationAction: WKNavigationAction, decisionHandler: (WKNavigationActionPolicy) -> Void) {
        
        // If the URL falls within the scope of any service worker, we want to redirect the
        // browser to our local web server with the cached responses rather than the internet.
       
        let urlForRequest = navigationAction.request.URL!
            
        if urlForRequest.host == "localhost" && urlForRequest.port == WebServer.current!.port {
            // Is already a request to our local web server, so allow
            decisionHandler(WKNavigationActionPolicy.Allow)
            return
        }
        
        ServiceWorkerManager.getServiceWorkerForURL(navigationAction.request.URL!)
        .then { (serviceWorker) -> Void in
            
            if (serviceWorker == nil) {
                
                // This is not inside any service worker scope, so allow
                
                decisionHandler(WKNavigationActionPolicy.Allow)
                return
            }
            
            let mappedURL = try serviceWorker!.getURLInsideServiceWorkerScope(navigationAction.request.URL!)
            decisionHandler(WKNavigationActionPolicy.Cancel)
            webView.loadRequest(NSURLRequest(URL: mappedURL))
            
        }
        .error { err in
            log.error(String(err))
            decisionHandler(WKNavigationActionPolicy.Allow)
            
        }
        
       
    }
}