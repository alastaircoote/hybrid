//
//  HybridWebviewController.swift
//  hybrid
//
//  Created by alastair.coote on 25/08/2016.
//  Copyright © 2016 Alastair Coote. All rights reserved.
//

import Foundation
import UIKit
import EmitterKit
import PromiseKit
import WebKit

class HybridWebviewController : UIViewController, WKNavigationDelegate {
    
    var currentMetadata:HybridWebviewMetadata?
    
    
    let events = Event<HybridWebviewController>()
    
    var webview:HybridWebview? {
        get {
            return self.view as? HybridWebview
        }
    }
    
   
//    let hybridNavigationController:HybridNavigationController
    
    var hybridNavigationController:HybridNavigationController? {
        get {
            return self.navigationController as? HybridNavigationController
        }
    }

    
    init() {
        super.init(nibName: nil, bundle: nil)
        
        self.view = HybridWebview(frame: self.view.frame)

        self.webview!.registerWebviewForServiceWorkerEvents()
        
        self.webview!.navigationDelegate = self
        
        // Don't show text in back button - it's causing some odd display problems
        self.navigationItem.backBarButtonItem = UIBarButtonItem(title: "", style: .Plain, target: nil, action: nil)
    }
    
    
    func loadURL(urlToLoad:NSURL) {
        self.checkIfURLInsideServiceWorker(urlToLoad)
        .then { (url, sw) -> Promise<Void> in
            
            
            if self.webview!.URL == nil || self.webview!.URL!.host != "localhost" || self.webview!.URL!.path!.containsString("__placeholder") {
                self.webview!.loadRequest(NSURLRequest(URL: url))
                self.view = self.webview
                return Promise<Void>()
            }
            
            
            let fr = FetchRequest(url: urlToLoad.absoluteString!, options: nil)
            
            return sw!.dispatchFetchEvent(fr)
            .then { response -> Promise<Void> in
                let responseAsString = String(data: response!.data!, encoding: NSUTF8StringEncoding)!
                
                let responseEscaped = responseAsString.stringByReplacingOccurrencesOfString("\"", withString: "\\\"")
                
                return Promise<Void> { fulfill, reject in
                    self.webview!.evaluateJavaScript("__setHTML(\"" + responseEscaped + "\",\"" + url.absoluteString! + "\");",completionHandler: { (obj:AnyObject?, err: NSError?) in
                        if err != nil {
                            // Injecting HTML failed. Why?
                            
                            reject(err!)
                        } else {
                            fulfill()
                        }
                    })
                }
                .then { () -> Promise<Void> in
                    
                    return when(
                        self.waitForRendered(),
                        self.setMetadata()
                    )
                }
                .recover { err -> Void in
                    log.error(String(err))
                    self.webview!.loadRequest(NSURLRequest(URL: url))
                }
                
                

                
                
            }
            .then { () -> Void in
                self.events.emit("ready", self)
            }
            
            
            
        }
        .error {err in
            self.webview!.loadRequest(NSURLRequest(URL: urlToLoad))
        }
    }
    
    func prepareHeaderControls(alreadyHasBackControl:Bool) {
        
        // We've included the ability for webviews to specify a default "back" URL, but if
        // we already have a back control then we don't need to use it.
        
//        if alreadyHasBackControl == true || self.currentMetadata?.defaultBackURL == nil {
//            self.navigationItem.leftBarButtonItem = nil
//            return
//        }
//        
//        let backTo = BackButtonSymbol(onTap: self.popToCustomBackWebView)
//        backTo.sizeToFit()
//        let back = UIBarButtonItem(customView: backTo)
//        self.navigationItem.leftBarButtonItem = back
    }
    
    func popToCustomBackWebView() {
        let relativeURL = NSURL(string: self.currentMetadata!.defaultBackURL!, relativeToURL: self.webview!.URL!)!
        self.hybridNavigationController!.popToNewHybridWebViewControllerFor(relativeURL)
    }
    
    func fiddleContentInsets() {
        
        // No idea why, but when pushing a viewcontroller in from the staging area the insets sometimes
        // get messed up. Resetting them on push seems to work, though.
        
        self.webview!.scrollView.contentInset = UIEdgeInsets(top: 1, left: 0, bottom: 0, right: 0)
    }
    
    func checkIfURLInsideServiceWorker(url:NSURL) -> Promise<(NSURL,ServiceWorkerInstance?)> {
        return ServiceWorkerManager.getServiceWorkerForURL(url)
        .then { (serviceWorker) -> (NSURL,ServiceWorkerInstance?) in
            
            if (serviceWorker == nil) {
                
                // This is not inside any service worker scope, so allow
                
                return (url,nil)
            }
            
            return (WebServer.current!.mapRequestURLToServerURL(url), serviceWorker)
        }

    }
    
    func webView(webView: WKWebView, decidePolicyForNavigationAction navigationAction: WKNavigationAction, decisionHandler: (WKNavigationActionPolicy) -> Void) {
        
        if navigationAction.navigationType != WKNavigationType.LinkActivated {
            decisionHandler(WKNavigationActionPolicy.Allow)
            return
        }
        
        var intendedURL = navigationAction.request.URL!
        
        if WebServer.current!.isLocalServerURL(intendedURL) {
            intendedURL = WebServer.checkServerURLForReferrer(navigationAction.request.URL!, referrer: navigationAction.request.allHTTPHeaderFields!["Referer"])
            intendedURL = WebServer.mapServerURLToRequestURL(intendedURL)
        }
        
        
        self.hybridNavigationController!.pushNewHybridWebViewControllerFor(intendedURL)
        decisionHandler(WKNavigationActionPolicy.Cancel)
    }
    
    func webView(webView: WKWebView, didFinishNavigation navigation: WKNavigation!) {
        self.setMetadata()
        .then {
            self.events.emit("ready", self)
        }
    }
    
    func setMetadata() -> Promise<Void> {
        return self.webview!.getMetadata()
        .then { metadata -> Void in
            self.currentMetadata = metadata
            
        }
    }
    
    override func viewWillAppear(animated: Bool) {
        super.viewWillAppear(animated)
        // Need this otherwise the title sometimes disappears
        if self.hybridNavigationController != nil && self.currentMetadata != nil {
            self.navigationItem.title = self.currentMetadata!.title
        }
    }
    
    override func preferredStatusBarStyle() -> UIStatusBarStyle {
        return UIStatusBarStyle.LightContent
    }
    
    override func viewDidDisappear(animated: Bool) {
        
        super.viewDidDisappear(animated)
        
        if self.navigationController == nil {
            self.events.emit("popped", self)
//            self.hybridNavigationController!.addControllerToWaitingArea(self)
        }
        
    }
    
    var renderCheckContext:CGContext?
    var pixel:UnsafeMutablePointer<CUnsignedChar>?
    
    func checkIfRendered() -> Bool {
        
        // Because WKWebView lives on a separate process, it's very difficult to guarantee when
        // rendering has actually happened. To avoid the flash of white when we push a controller,
        // we take a width * 1px screenshot, and detect a dummy pixel we've put in the top right of
        // the page in a custom color. If it isn't detected, waitForRender() fires again at the next
        // interval.
        
        let height = 1
        let width = Int(self.view.frame.width)
        
        if self.renderCheckContext == nil {
            
            self.pixel = UnsafeMutablePointer<CUnsignedChar>.alloc(4 * width * height)
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.PremultipliedLast.rawValue)
            self.renderCheckContext = CGBitmapContextCreate(pixel!, width, height, 8, width * 4, colorSpace, bitmapInfo.rawValue)!
        }
        

        self.webview!.scrollView.layer.renderInContext(self.renderCheckContext!)
        
        let startAt = 4 * width * height - 4
        
        let red = CGFloat(pixel![startAt])
        let green = CGFloat(pixel![startAt + 1])
        let blue =  CGFloat(pixel![startAt + 2])
//        let alpha = CGFloat(pixel![startAt + 3])
        
       
        return red == 0 && blue == 255 && green == 255
        
//        let imgref = CGBitmapContextCreateImage(self.renderCheckContext!)
//        let uiImage = UIImage(CGImage: imgref!)
//        
//        AppDelegate.window!.addSubview(UIImageView(image: uiImage))
    }
    
    private func waitRenderWithFulfill(fulfill: () -> ()) {
        if self.checkIfRendered() == true {
            log.debug("Checked if webview was ready, it WAS")
            self.renderCheckContext = nil
            self.pixel!.destroy()
            self.pixel = nil
            
            self.webview!.evaluateJavaScript("__removeLoadedIndicator()", completionHandler: nil)
//            self.events.emit("ready", "test")
            fulfill()
        } else {
            log.debug("Checked if webview was ready, it was not")
            let triggerTime = (Double(NSEC_PER_SEC) * 0.05)
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, Int64(triggerTime)), dispatch_get_main_queue(), { () -> Void in
                self.waitRenderWithFulfill(fulfill)
            })
        }
    }
    
    func waitForRendered() -> Promise<Void> {
        return Promise<Void> { fulfill, reject in
            self.waitRenderWithFulfill(fulfill)
        }
    }
    
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    
}
