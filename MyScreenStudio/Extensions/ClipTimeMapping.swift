import Foundation

/// Represents a mapping entry between composition time and source time for a single clip.
typealias ClipTimeEntry = (compositionStart: Double, sourceStart: Double, duration: Double)

/// Shared utilities for remapping times between source and composition timelines.
enum ClipTimeMapping {

    /// Build a clip time map from an ordered array of video clips.
    static func buildTimeMap(from clips: [VideoClip]) -> [ClipTimeEntry] {
        let active = clips.filter { $0.duration > 0 }
        guard !active.isEmpty else { return [] }

        var map: [ClipTimeEntry] = []
        var insertionTime: Double = 0
        for clip in active {
            map.append((compositionStart: insertionTime,
                        sourceStart: clip.sourceStart,
                        duration: clip.duration))
            insertionTime += clip.duration
        }
        return map
    }

    /// Convert a source time to composition time.
    /// Returns nil if the source time falls in a gap (deleted/excluded segment).
    static func sourceToCompositionTime(
        _ sourceTime: Double,
        clipTimeMap: [ClipTimeEntry]
    ) -> Double? {
        for entry in clipTimeMap {
            let sourceEnd = entry.sourceStart + entry.duration
            if sourceTime >= entry.sourceStart && sourceTime <= sourceEnd {
                return entry.compositionStart + (sourceTime - entry.sourceStart)
            }
        }
        return nil
    }

    /// Convert a composition time back to source time.
    /// Returns nil if the time doesn't map to any clip.
    static func compositionToSourceTime(
        _ compositionTime: Double,
        clipTimeMap: [ClipTimeEntry]
    ) -> Double? {
        for entry in clipTimeMap {
            let compEnd = entry.compositionStart + entry.duration
            if compositionTime >= entry.compositionStart && compositionTime <= compEnd {
                return entry.sourceStart + (compositionTime - entry.compositionStart)
            }
        }
        return nil
    }

    /// Remap zoom segments from source timeline to composition timeline.
    /// Segments that partially overlap clips are clipped to the visible range.
    /// Segments that fall entirely in gaps are dropped.
    static func remapZoomSegments(
        _ segments: [ZoomSegment],
        clipTimeMap: [ClipTimeEntry]
    ) -> [ZoomSegment] {
        var result: [ZoomSegment] = []

        for seg in segments {
            let segEnd = seg.start + seg.duration

            for entry in clipTimeMap {
                let clipSourceEnd = entry.sourceStart + entry.duration

                let overlapStart = max(seg.start, entry.sourceStart)
                let overlapEnd = min(segEnd, clipSourceEnd)
                guard overlapEnd > overlapStart else { continue }

                let compStart = entry.compositionStart + (overlapStart - entry.sourceStart)
                let compDuration = overlapEnd - overlapStart

                var remapped = seg
                remapped.start = compStart
                remapped.duration = compDuration
                result.append(remapped)
            }
        }

        return result
    }

    /// Remap cursor metadata event timestamps from source to composition timeline.
    /// Events in gaps are dropped.
    static func remapCursorMetadata(
        _ metadata: CursorMetadata,
        clipTimeMap: [ClipTimeEntry]
    ) -> CursorMetadata {
        var remapped = metadata
        remapped.events = metadata.events.compactMap { event in
            guard let compTime = sourceToCompositionTime(event.timestamp, clipTimeMap: clipTimeMap) else {
                return nil
            }
            return MouseEvent(
                timestamp: compTime,
                position: event.position,
                type: event.type,
                windowFrame: event.windowFrame
            )
        }
        return remapped
    }
}
