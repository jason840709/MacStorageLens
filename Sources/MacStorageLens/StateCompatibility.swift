import SwiftUI

// Select the existing public property wrapper explicitly. SDK 27 also declares
// an @State macro whose plugin is absent from standalone Command Line Tools.
// Keep the initialization and Binding semantics used by this macOS 14+ app.
typealias LensState<Value> = SwiftUI.State<Value>
