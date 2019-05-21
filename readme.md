# hybrid

## What is this?

An experimental app that implements (some) Service Worker APIs in a native iOS app. This repo specifically is a fork of [a Guardian Mobile Lab project](https://github.com/gdnmobilelab/hybrid) that was written in 2017, updated very slightly so that it'll build in 2019 and point to [this test worker](https://github.com/alastaircoote/hybrid-test-worker/) script that will demo some functionality.

## What is this not?

Production ready in any way, shape or form. It was an extended proof of concept testing whether service worker APIs are replicable or not, rather than making a bullet-proof app. I was also learning Swift at the same time as writing this, so the code is awful (exclamation marks everywhere!) and memory usage is not great, though I learned a lot about how memory is handled in JavaScriptCore in the process of writing this app.

Some of the ideas presented here were rewritten as part of [SWWebView](https://github.com/gdnmobilelab/SWWebView), but not things like notifications, which form a core part of the demo. SWWebView also uses the far, far more sensible method of WKURLSchemeHandler (not available when I wrote this) to intercept web requests, rather than starting up a local web server.

## Requirements

- XCode >= 8
- Node >= 6
- Cocoapods

## Installation

Clone the repo. Then run:

    cd hybrid
    pod install
    cd js-src
    npm install --production

Once you've done that you should be able to open
`hybrid.xcworkspace` and build the project successfully.
