import SwiftUI
import MRCarveKit

/// Raster settings with a live dithered preview.
struct ImageSection: View {
    let document: DocumentModel
    let cache: PreviewCache
    let object: DesignObject

    var body: some View {
        let raster = document.rasterBinding(object.id)
        let settings = raster.wrappedValue
        Section(L("Image")) {
            preview
            Picker(L("Dithering"), selection: raster.dither) {
                ForEach(DitherMode.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            if settings.dither == .threshold {
                SliderField(title: L("Threshold"), value: percent(raster.threshold), range: 0...100, unit: "%")
            }
            LabeledContent(L("Line interval")) {
                HStack(spacing: 4) {
                    TextField(L("Line interval"), value: Binding(get: { settings.lineInterval },
                                                                 set: { if $0.isFinite { raster.wrappedValue.lineInterval = min(max($0, 0.005), 1) } }),
                              format: .number.precision(.fractionLength(0...3)))
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 64)
                    Text("mm").foregroundStyle(.secondary).font(.callout)
                    Text("≈ \(Format.number(25.4 / max(settings.lineInterval, 0.001), digits: 0)) DPI")
                        .foregroundStyle(.secondary).font(.callout.monospacedDigit())
                }
            }
            SliderField(title: L("Brightness"), value: percent(raster.brightness), range: -100...100, unit: "%")
            SliderField(title: L("Contrast"), value: percent(raster.contrast), range: -100...100, unit: "%")
            SliderField(title: L("Gamma"), value: raster.gamma, range: 0.2...3, digits: 2)
            Toggle(L("Invert"), isOn: raster.invert)
            Toggle(L("Bidirectional scanning"), isOn: raster.bidirectional)
            NumberField(title: L("Scan angle"), value: raster.scanAngle, unit: "°", range: -90...90, step: 15)
            if case .image(let content) = object.kind {
                LabeledContent(L("Pixels"), value: "\(content.pixelWidth) × \(content.pixelHeight)")
                if !content.sourceName.isEmpty { LabeledContent(L("Source"), value: content.sourceName) }
            }
        }
    }

    private func percent(_ binding: Binding<Double>) -> Binding<Double> {
        Binding(get: { binding.wrappedValue * 100 }, set: { binding.wrappedValue = $0 / 100 })
    }

    @ViewBuilder
    private var preview: some View {
        let _ = cache.revision
        let result = cache.rasterPreview(object)
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(Color.white)
            if let image = result.image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.none)
                    .aspectRatio(contentMode: .fit)
                    .padding(4)
            } else if !result.isPending {
                VStack(spacing: 4) {
                    Image(systemName: "photo").font(.title2)
                    Text(L("Preview unavailable")).font(.caption)
                }
                .foregroundStyle(.secondary)
            }
            if result.isPending {
                ProgressView().controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(8)
            }
        }
        .frame(height: 150)
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
        .accessibilityLabel(L("Dithered preview"))
    }
}
