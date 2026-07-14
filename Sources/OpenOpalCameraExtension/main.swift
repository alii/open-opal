// The entry point of the CMIO camera extension. This process is launched and
// owned by the SYSTEM, not by the Open Opal app — it starts when something asks
// for the camera and keeps running independently. The app talks to it only by
// writing frames into the sink stream.

import CoreMediaIO
import Foundation

let providerSource = CameraProviderSource(clientQueue: nil)
CMIOExtensionProvider.startService(provider: providerSource.provider)
CFRunLoopRun()
