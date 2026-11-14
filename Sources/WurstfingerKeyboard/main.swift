#if os(iOS)
import WurstfingerKit

// The extension's real entry point is `_NSExtensionMain` (set via linker
// flags in Package.swift); this reference only keeps the linker from
// stripping the principal class named in the extension's Info.plist.
private let keepPrincipalClass: AnyClass = KeyboardViewController.self
#else
print("The Wurstfinger keyboard extension is iOS-only.")
#endif
