import SwiftUI

struct ExchangeView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let store = env.exchange
        NavigationStack {
            List {
                if let cached = store.cached {
                    let rates = cached.value
                    Section("1外貨あたりの円") {
                        ForEach(env.settings.exchangeCodes, id: \.self) { code in
                            rateRow(code, rates: rates)
                        }
                    }
                    Section("換算") {
                        ConverterView(rates: rates, codes: env.settings.exchangeCodes)
                    }
                    Section {
                        LabeledContent("レートの基準時刻", value: Formatters.dateTime.string(from: rates.providerUpdatedAt))
                        LabeledContent("次回の更新予定", value: Formatters.dateTime.string(from: rates.nextUpdateAt))
                    } footer: {
                        Text("日次のレートです。リアルタイムの値ではありません。")
                    }
                } else if !store.isLoading {
                    ContentUnavailableView("為替は未取得です", systemImage: "yensign.circle", description: Text("右上の更新ボタンで取得できます"))
                }
                Section {
                    NavigationLink("表示する通貨を選ぶ") {
                        CurrencyPickerView(available: store.cached?.value.availableCodes ?? AppSettings.defaultExchangeCodes)
                    }
                }
                Section {
                    DataStatusView(fetchedAt: store.cached?.fetchedAt, note: store.autoRefreshNote, error: store.errorMessage)
                } footer: {
                    Text("出典: Rates By Exchange Rate API (https://www.exchangerate-api.com)")
                }
            }
            .navigationTitle("為替")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    RefreshToolbarButton(isLoading: store.isLoading) { await store.refreshManually() }
                }
            }
            .task { await store.refreshIfStale() }
        }
    }

    private func rateRow(_ code: String, rates: ExchangeRates) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(code).font(.title3.weight(.bold))
                Text(CurrencyName.japanese(code)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let yen = rates.yenPerUnit(code) {
                BigValue(value: Self.yenText(yen), unit: "円", size: 34)
            } else {
                Text("データなし").foregroundStyle(.secondary)
            }
        }
    }

    /// 小さい値(KRWなど)は桁を増やす
    static func yenText(_ yen: Double) -> String {
        if yen >= 10 { return String(format: "%.2f", yen) }
        if yen >= 1 { return String(format: "%.3f", yen) }
        return String(format: "%.4f", yen)
    }
}

/// キャッシュしたレートだけで計算するのでオフラインでも動く
struct ConverterView: View {
    let rates: ExchangeRates
    let codes: [String]

    @AppStorage("exchange.converter.code") private var code = "USD"
    @AppStorage("exchange.converter.toYen") private var toYen = true
    @State private var amountText = ""

    private var amount: Double? {
        Double(amountText.replacingOccurrences(of: ",", with: ""))
    }

    private var result: Double? {
        guard let amount else { return nil }
        return toYen ? rates.toYen(amount, from: code) : rates.fromYen(amount, to: code)
    }

    var body: some View {
        Picker("通貨", selection: $code) {
            ForEach(codes.contains(code) ? codes : codes + [code], id: \.self) { c in
                Text("\(c) \(CurrencyName.japanese(c))").tag(c)
            }
        }
        Picker("方向", selection: $toYen) {
            Text("\(code) → 円").tag(true)
            Text("円 → \(code)").tag(false)
        }
        .pickerStyle(.segmented)
        HStack {
            TextField("金額", text: $amountText)
                .keyboardType(.decimalPad)
                .font(.title2.monospacedDigit())
            Text(toYen ? code : "円").foregroundStyle(.secondary)
        }
        HStack {
            Text("=").foregroundStyle(.secondary)
            Spacer()
            BigValue(value: result.map(Self.resultText) ?? "-", unit: toYen ? "円" : code, size: 36)
        }
    }

    static func resultText(_ value: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 2
        f.minimumFractionDigits = 0
        return f.string(from: NSNumber(value: value)) ?? String(value)
    }
}

struct CurrencyPickerView: View {
    @Environment(AppEnvironment.self) private var env
    let available: [String]
    @State private var query = ""

    private var filtered: [String] {
        let q = query.trimmingCharacters(in: .whitespaces).uppercased()
        guard !q.isEmpty else { return available }
        return available.filter { $0.contains(q) || CurrencyName.japanese($0).contains(query) }
    }

    var body: some View {
        let settings = env.settings
        List {
            Section("表示中(並べ替え可)") {
                ForEach(settings.exchangeCodes, id: \.self) { code in
                    Text("\(code) \(CurrencyName.japanese(code))")
                }
                .onDelete { settings.exchangeCodes.remove(atOffsets: $0) }
                .onMove { settings.exchangeCodes.move(fromOffsets: $0, toOffset: $1) }
            }
            Section("追加") {
                ForEach(filtered.filter { !settings.exchangeCodes.contains($0) }, id: \.self) { code in
                    Button {
                        settings.exchangeCodes.append(code)
                    } label: {
                        Label("\(code) \(CurrencyName.japanese(code))", systemImage: "plus.circle")
                    }
                }
            }
        }
        .searchable(text: $query, prompt: "通貨コードまたは名前")
        .navigationTitle("通貨")
        .toolbar { EditButton() }
    }
}
