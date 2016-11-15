//
//  LoadingIndicatorJS.swift
//  hybrid
//
//  Created by alastair.coote on 04/11/2016.
//  Copyright © 2016 Alastair Coote. All rights reserved.
//

import Foundation


/// Kind of daft, but this class is a tiny store for JS snippets we use in the course of
/// loading webviews. It could be moved into js-src and injected into document-start.js
/// in the future, as all webviews should have access to it. Also hopefully Swift
/// introduces multi-line strings soon.

class WebviewJS {
    
    static var setLoadingIndicator:String {
        get {
            let js:[String] = [
                "loadedIndicator = document.createElement('div');",
                "loadedIndicator.style.position = 'absolute';",
                "loadedIndicator.style.right = '0px';",
                "loadedIndicator.style.top = '0px';",
                "loadedIndicator.style.width = '1px';",
                "loadedIndicator.style.height = '1px';",
                "loadedIndicator.style.backgroundColor = 'rgb(0,255,255)';",
                "loadedIndicator.style.zIndex = '999999';",
                "document.body.appendChild(loadedIndicator);",
                "window.__loadedIndicator = loadedIndicator;",
                "true" // have to return true otherwise js evaluate complains about trying to return a DOM node
            ]
            
            return js.joinWithSeparator("")
        }
    }
    
    static var removeLoadingIndicator:String {
        get {
            return "document.body.removeChild(window.__loadedIndicator); delete window.__loadedIndicator;"
        }
    }
    
    static var getMetadataJS:String {
        get {
            return (["var getMeta = function(name) {",
                    "   var t = document.querySelector(\"meta[name='\" + name + \"']\");",
                    "   return t ? t.getAttribute('content') : null;",
                    "};",
                    "[getMeta('theme-color'), document.title, getMeta('default-back-url')]"
                    ] as [String]).joinWithSeparator("")
        }
    }
}