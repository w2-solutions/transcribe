import Foundation

public enum ColourAssigner {
    /// Slot per speaker for one recording (see §5.4).
    ///
    /// 1. Speakers with a `profileSlot`, in ordinal order, take that slot while it is still free.
    /// 2. Every remaining speaker, in ordinal order, takes the lowest free slot; once all slots are used it takes
    ///    `(ordinal − 1) % slotCount`.
    ///
    /// Ordinal ties are broken by key, so the result does not depend on the order of `requests`. A repeated key
    /// is placed only once, using its first request in that order. Profile slots outside `0..<slotCount` are wrapped into range.
    public static func assign(_ requests: [ColourRequest], slotCount: Int = SpeakerSlots.count) -> [SpeakerKey: Int] {
        guard slotCount > 0 else { return Dictionary(requests.map { ($0.key, 0) }, uniquingKeysWith: { a, _ in a }) }
        var seen = Set<SpeakerKey>()
        let ordered = requests
            .sorted { a, b in a.ordinal != b.ordinal ? a.ordinal < b.ordinal : a.key < b.key }
            .filter { seen.insert($0.key).inserted }
        var result: [SpeakerKey: Int] = [:]
        var used = Set<Int>()

        for r in ordered where result[r.key] == nil {
            guard let raw = r.profileSlot else { continue }
            let slot = wrap(raw, slotCount)
            if used.insert(slot).inserted { result[r.key] = slot }
        }
        for r in ordered where result[r.key] == nil {
            let slot = lowestFree(used, slotCount) ?? wrap(r.ordinal - 1, slotCount)
            used.insert(slot)
            result[r.key] = slot
        }
        return result
    }

    /// Speaker `key` takes `profileSlot`; any other speaker holding it moves to the lowest free slot.
    ///
    /// When no slot is free (more speakers than slots), a displaced speaker takes the slot `key` gave up, or keeps
    /// sharing `profileSlot` if `key` had none. Displaced speakers are moved in key order.
    public static func reassign(key: SpeakerKey, toProfileSlot profileSlot: Int, current: [SpeakerKey: Int],
                                slotCount: Int = SpeakerSlots.count) -> [SpeakerKey: Int] {
        guard slotCount > 0 else { var c = current; c[key] = profileSlot; return c }
        let target = wrap(profileSlot, slotCount)
        let vacated = current[key]
        var result = current
        result[key] = target

        let holders = current.filter { $0.key != key && $0.value == target }.map(\.key).sorted()
        var used = Set(result.filter { !holders.contains($0.key) }.values)
        var spare = vacated.flatMap { $0 != target ? $0 : nil }
        for holder in holders {
            if let slot = lowestFree(used, slotCount) {
                result[holder] = slot; used.insert(slot)
            } else if let slot = spare {
                result[holder] = slot; used.insert(slot); spare = nil
            }
            // Otherwise the holder keeps sharing `target`: every slot is already in use.
        }
        return result
    }

    /// Slot for a brand-new profile created from a speaker: the speaker's slot unless another
    /// profile already owns it, then the lowest slot no profile owns (wraps if all are used).
    ///
    /// "Wraps" means that when every slot is owned the profile keeps the speaker's slot, so the person's colour
    /// does not change at the moment they are named.
    public static func slotForNewProfile(speakerSlot: Int, profileSlots: Set<Int>,
                                         slotCount: Int = SpeakerSlots.count) -> Int {
        guard slotCount > 0 else { return speakerSlot }
        let own = wrap(speakerSlot, slotCount)
        let owned = Set(profileSlots.map { wrap($0, slotCount) })
        if !owned.contains(own) { return own }
        return lowestFree(owned, slotCount) ?? own
    }

    // MARK: - Helpers

    private static func lowestFree(_ used: Set<Int>, _ slotCount: Int) -> Int? {
        (0..<slotCount).first { !used.contains($0) }
    }

    private static func wrap(_ value: Int, _ slotCount: Int) -> Int {
        ((value % slotCount) + slotCount) % slotCount
    }
}
