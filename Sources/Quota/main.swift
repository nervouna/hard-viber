import Foundation
import QuotaKit

// build.sh copies the collector, the row list and the artwork into Contents/Resources.
QuotaApp.run(resources: AppResources(directory: Bundle.main.resourceURL ?? Bundle.main.bundleURL))
