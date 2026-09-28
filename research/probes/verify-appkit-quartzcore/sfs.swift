import AppKit
for n in ["gpu","bluetooth","thermometer.variable","wifi","gauge.with.needle","cpu","memorychip","fan","gauge.range.33to100.dotted.with.needle","battery.100percent","network","internaldrive"] {
  let base = NSImage(systemSymbolName: n, variableValue: 0.6, accessibilityDescription: nil)
  let draw = base?.withSymbolConfiguration(.init(variableValueMode: .draw))
  let color = base?.withSymbolConfiguration(.init(variableValueMode: .color))
  print("\(n): base=\(base != nil) draw=\(draw != nil) color=\(color != nil) template=\(base?.isTemplate ?? false)")
}
