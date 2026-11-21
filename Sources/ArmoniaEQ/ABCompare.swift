import Foundation

/// Confronto A/B tra due configurazioni (curva completa: 10 bande, preamp, BASSI, ALTI).
/// Le configurazioni sono temporanee (solo in memoria) e non toccano i profili salvati.
/// La configurazione attiva è sempre quella in ascolto: le modifiche fatte mentre è attiva
/// la B restano nella B; tornando ad A si ritrova A esattamente com'era.
struct ABCompare: Equatable {
    enum Slot: String { case a = "A", b = "B" }

    private(set) var active: Slot = .a
    private(set) var stored: [Slot: EQSettings] = [:]

    var isInUse: Bool { !stored.isEmpty }

    /// Passa all'altra configurazione. `current` è la curva in ascolto (che appartiene allo slot
    /// attivo). Restituisce la curva da applicare: quella memorizzata nello slot richiesto, oppure,
    /// al primo uso, una copia della corrente (il suono non cambia finché non lo modifichi).
    mutating func switchTo(_ slot: Slot, current: EQSettings) -> EQSettings {
        stored[active] = current
        active = slot
        if let s = stored[slot] { return s }
        stored[slot] = current
        return current
    }

    mutating func toggle(current: EQSettings) -> EQSettings {
        switchTo(active == .a ? .b : .a, current: current)
    }

    /// Copia la configurazione in ascolto nell'altro slot.
    mutating func copyActiveToOther(current: EQSettings) {
        stored[active] = current
        stored[active == .a ? .b : .a] = current
    }

    func settings(for slot: Slot, current: EQSettings) -> EQSettings? {
        slot == active ? current : stored[slot]
    }

    mutating func reset() {
        stored = [:]
        active = .a
    }
}
