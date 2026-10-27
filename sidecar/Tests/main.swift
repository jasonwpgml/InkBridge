import Foundation

var checks = 0

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    guard condition() else { fatalError("FAIL: \(message)") }
}

func expectFailure(_ message: String, _ action: () throws -> Void) {
    checks += 1
    do { try action() } catch { return }
    fatalError("FAIL: \(message)")
}

func stroke(_ y: Double, tool: InkTool = .pen) -> InkStroke {
    InkStroke(tool: tool, color: InkColor(red: 1, green: 0.2, blue: 0.3), width: 4,
              points: [InkPoint(x: 0.1, y: y), InkPoint(x: 0.9, y: y)])
}

func fileData(_ strokes: [InkStroke], version: Int = 1) throws -> Data {
    struct File: Encodable { var version: Int; var strokes: [InkStroke] }
    return try JSONEncoder().encode(File(version: version, strokes: strokes))
}

let document = InkDocument()
let first = stroke(0.2)
let second = stroke(0.4)
let third = stroke(0.6)
document.add(first)
document.add(second)
check(document.strokes == [first, second], "add order")
document.undo()
check(document.strokes == [first] && document.canRedo, "undo exposes redo")
document.redo()
check(document.strokes == [first, second], "redo restores stroke")
document.undo()
document.add(third)
check(document.strokes == [first, third] && !document.canRedo, "new edit discards redo branch")

document.replace(with: [first, second, third])
document.beginErase()
document.erase(at: InkPoint(x: 0.5, y: 0.2), canvasWidth: 1_000, canvasHeight: 500, radius: 3)
document.erase(at: InkPoint(x: 0.5, y: 0.6), canvasWidth: 1_000, canvasHeight: 500, radius: 3)
document.endErase()
check(document.strokes == [second], "erase hits segment between widely spaced vertices")
document.undo()
check(document.strokes == [first, second, third], "one undo restores an entire erase drag and order")
check(!document.canUndo && document.canRedo, "erase drag contributes one history entry")
document.redo()
check(document.strokes == [second], "redo grouped erase")
document.clear()
check(document.strokes.isEmpty, "clear")
document.undo()
check(document.strokes == [second], "undo clear")

let tap = InkStroke(tool: .pen, color: first.color, width: 10, points: [InkPoint(x: 0.5, y: 0.5)])
document.replace(with: [tap])
document.erase(at: InkPoint(x: 0.5, y: 0.51), canvasWidth: 500, canvasHeight: 500, radius: 1)
check(document.strokes.isEmpty, "tap erases using visible stroke width")
document.undo()
document.erase(at: InkPoint(x: 0.9, y: 0.9), canvasWidth: 500, canvasHeight: 500, radius: 1)
check(document.canRedo, "missed erase preserves redo")

let arrow = stroke(0.5, tool: .arrow)
document.replace(with: [arrow])
document.erase(at: InkPoint(x: 0.9 - 13.856 / 1000, y: 0.5 + 8 / 500), canvasWidth: 1000, canvasHeight: 500, radius: 0.1)
check(document.strokes.isEmpty, "erase detects arrowhead off shaft")

document.replace(with: [first, second, third])
let encoded = try document.encoded()
let decoded = try InkDocument.decode(encoded)
check(decoded == document.strokes, "round trip preserves IDs, tools, colors and points")
check(!document.canUndo && !document.canRedo, "replace starts fresh history")
expectFailure("unknown schema") { _ = try InkDocument.decode(fileData([first], version: 99)) }
expectFailure("malformed JSON") { _ = try InkDocument.decode(Data("not json".utf8)) }
expectFailure("eraser must not be stored") { _ = try InkDocument.decode(fileData([stroke(0.5, tool: .eraser)])) }
expectFailure("duplicate IDs") { _ = try InkDocument.decode(fileData([first, first])) }

var invalid = first
invalid.points[0].x = -0.1
expectFailure("out-of-range coordinates") { _ = try InkDocument.decode(fileData([invalid])) }
invalid = first
invalid.color.blue = 2
expectFailure("out-of-range color") { _ = try InkDocument.decode(fileData([invalid])) }
invalid = first
invalid.width = 0
expectFailure("invalid line width") { _ = try InkDocument.decode(fileData([invalid])) }
invalid = first
invalid.points = []
expectFailure("empty stroke") { _ = try InkDocument.decode(fileData([invalid])) }
invalid = first
invalid.points = Array(repeating: InkPoint(x: 0.5, y: 0.5), count: 20_001)
expectFailure("too many points per stroke") { _ = try InkDocument.decode(fileData([invalid])) }

let tooManyStrokes = (0..<4_097).map { _ in stroke(0.5) }
expectFailure("too many strokes") { _ = try InkDocument.decode(fileData(tooManyStrokes)) }
let tooManyTotalPoints = (0..<13).map { _ -> InkStroke in
    var longStroke = stroke(0.5)
    longStroke.points = Array(repeating: InkPoint(x: 0.5, y: 0.5), count: 20_000)
    return longStroke
}
expectFailure("total point budget") { _ = try InkDocument.decode(fileData(tooManyTotalPoints)) }

let raw = String(data: try fileData([first]), encoding: .utf8)!
let hugeNumber = raw.replacingOccurrences(of: "\"width\":4", with: "\"width\":1e999")
expectFailure("non-finite numeric input") { _ = try InkDocument.decode(Data(hugeNumber.utf8)) }
let unknownTool = raw.replacingOccurrences(of: "\"tool\":\"pen\"", with: "\"tool\":\"unknown\"")
expectFailure("unknown tool") { _ = try InkDocument.decode(Data(unknownTool.utf8)) }
expectFailure("file size bounded before decoding") { _ = try InkDocument.decode(Data(repeating: 32, count: 16 * 1024 * 1024 + 1)) }

invalid = first
invalid.width = .infinity
document.add(invalid)
document.replace(with: [invalid])
check(document.strokes == [first, second, third], "invalid in-memory input leaves document intact")

document.replace(with: [])
for _ in 0..<105 { document.add(stroke(0.5)) }
for _ in 0..<100 { document.undo() }
check(document.strokes.count == 5 && !document.canUndo, "undo history bounded to 100 edits")
for _ in 0..<100 { document.redo() }
check(document.strokes.count == 105 && !document.canRedo, "redo restores bounded history")

document.beginErase()
document.erase(at: InkPoint(x: 0.5, y: 0.5), canvasWidth: 100, canvasHeight: 100, radius: 1)
document.undo()
check(document.strokes.count == 105, "undo commits and reverses an active erase transaction")

let curved = InkStroke(tool: .pen, color: first.color, width: 4,
    points: [InkPoint(x: 0.1, y: 0.2), InkPoint(x: 0.5, y: 0.8), InkPoint(x: 0.9, y: 0.2)])
document.replace(with: [curved])
document.erase(at: InkPoint(x: 0.5, y: 0.8), canvasWidth: 100, canvasHeight: 100, radius: 2)
check(document.strokes.count == 1, "eraser ignores original corner that smoothing removed")
document.erase(at: InkPoint(x: 0.5, y: 0.6), canvasWidth: 100, canvasHeight: 100, radius: 2)
check(document.strokes.isEmpty, "eraser follows the visible smoothed curve")
document.undo()
check(document.strokes == [curved], "undo preserves original editable samples of curved stroke")

document.replace(with: [first, second])
document.beginErase()
document.erase(at: InkPoint(x: 0.5, y: 0.3), from: InkPoint(x: 0.5, y: 0.1),
               canvasWidth: 1000, canvasHeight: 500, radius: 8, mode: .partial)
check(document.strokes.count == 2 && document.strokes[0].erasures?.count == 1 && document.strokes[1].erasures == nil,
      "swept partial erase catches crossed ink without changing untouched strokes")
document.erase(at: InkPoint(x: 0.8, y: 0.3), from: InkPoint(x: 0.5, y: 0.3),
               canvasWidth: 1000, canvasHeight: 500, radius: 8, mode: .partial)
document.endErase()
let cut = document.strokes
check(cut[0].points == first.points && cut[0].erasures!.first!.points.count == 3,
      "partial erase preserves original ink and records continuous sweep")
document.undo()
check(document.strokes == [first, second] && !document.canUndo, "one undo restores entire partial erase gesture")
document.redo()
check(document.strokes == cut, "partial erase redo restores exact mask")
let restoredCut = try InkDocument.decode(document.encoded())
check(restoredCut == cut, "partial erasures survive save and load")
document.erase(at: InkPoint(x: 0.5, y: 0.2), canvasWidth: 1000, canvasHeight: 500, radius: 1)
check(document.strokes == cut, "whole-stroke eraser ignores an already erased gap")
document.beginErase()
document.erase(at: InkPoint(x: 0.7, y: 0.4), canvasWidth: 1000, canvasHeight: 500, radius: 8, mode: .partial)
document.undo()
check(document.strokes == cut, "undo while erasing commits then restores active partial gesture")
document.replace(with: [first])
document.erase(at: InkPoint(x: 0.5, y: 0.3), from: InkPoint(x: 0.5, y: 0.1),
               canvasWidth: 1000, canvasHeight: 500, radius: 1)
check(document.strokes.isEmpty, "fast whole-stroke eraser detects a crossed line between pointer events")
document.undo()
document.erase(at: InkPoint(x: 0.5, y: 0.9), canvasWidth: 1000, canvasHeight: 500, radius: 8, mode: .partial)
check(document.strokes == [first] && document.canRedo, "missed partial erase preserves redo")
var invalidMask = first
invalidMask.erasures = [InkErasure(id: UUID(), radius: -1, points: [InkPoint(x: 0.5, y: 0.5)])]
expectFailure("invalid eraser radius") { _ = try InkDocument.decode(fileData([invalidMask], version: 2)) }
invalidMask.erasures![0].radius = 8
invalidMask.erasures![0].points[0].x = 1.5
expectFailure("out of bounds eraser point") { _ = try InkDocument.decode(fileData([invalidMask], version: 2)) }
document.replace(with: cut)
document.erase(at: InkPoint(x: 0.2, y: 0.2), canvasWidth: 1000, canvasHeight: 500, radius: 1)
check(document.strokes == [second], "whole-stroke eraser still removes visible remainder of a partially erased stroke")

document.replace(with: [])
check(document.add(first), "accepted stroke reports a cache append")
check(!document.add(first), "duplicate stroke must not append to the rendered cache")
check(!document.add(invalid), "invalid stroke must not append to the rendered cache")
document.beginErase()
check(document.erase(at: InkPoint(x: 0.5, y: 0.2), canvasWidth: 100, canvasHeight: 100, radius: 1),
      "whole-stroke hit reports a redraw")
check(!document.erase(at: InkPoint(x: 0.5, y: 0.9), canvasWidth: 100, canvasHeight: 100, radius: 1),
      "miss after a hit in the same gesture needs no redraw")
document.endErase(); document.undo()
check(document.strokes == [first], "skipped redraw does not discard the gesture's undo")
document.beginErase()
let erasePoint = InkPoint(x: 0.5, y: 0.2)
check(document.erase(at: erasePoint, canvasWidth: 100, canvasHeight: 100, radius: 3, mode: .partial),
      "partial hit reports a redraw")
check(!document.erase(at: erasePoint, canvasWidth: 100, canvasHeight: 100, radius: 3, mode: .partial),
      "stationary partial eraser needs no redraw")
document.endErase()

var toolSettings = InkToolSettings()
toolSettings[.pen] = InkToolStyle(color: InkColor(red: 0.88, green: 0.16, blue: 0.23), width: 2)
check(toolSettings[.highlighter].color == InkColor(red: 0.98, green: 0.77, blue: 0.12)
      && toolSettings[.highlighter].width == 4, "pen changes preserve the yellow highlighter style")
toolSettings[.highlighter].width = 7
toolSettings[.arrow].color = InkColor(red: 0.1, green: 0.57, blue: 0.32)
check(toolSettings[.pen].width == 2 && toolSettings[.arrow].width == 4,
      "pen, highlighter, and arrow keep independent widths")
let beforeEraser = toolSettings
toolSettings[.eraser] = InkToolStyle(color: InkColor(red: 1, green: 1, blue: 1), width: 8)
check(toolSettings == beforeEraser, "eraser cannot overwrite an ink style")
let toolSettingsData = try JSONEncoder().encode(toolSettings)
let decodedToolSettings = try JSONDecoder().decode(InkToolSettings.self, from: toolSettingsData)
check(decodedToolSettings == toolSettings,
      "tool style preferences survive a storage round trip")
print("InkModel: \(checks) checks passed")
