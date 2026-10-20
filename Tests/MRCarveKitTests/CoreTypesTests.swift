import Foundation
import MRCarveKit

enum CoreTypesTests {
    static func register() {
        test("closed polyline length") {
            let square = Rect2(minX: 0, minY: 0, maxX: 10, maxY: 5).outline
            expectClose(square.length, 30)
            expectEqual(square.traversal.count, 5)
        }

        test("job bounds and field") {
            let pen = PenParameters(id: 0)
            let job = MarkJob(items: [MarkItem(pen: pen, polylines: [Polyline([Vec2(-5, -5), Vec2(5, 5)])])])
            expectEqual(job.bounds, Rect2(minX: -5, minY: -5, maxX: 5, maxY: 5))
            expectClose(MachineProfile().field.width, 70)
        }
    }
}
