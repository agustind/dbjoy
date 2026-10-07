@testable import DBJoy
import Testing

struct ConnectionIconsTests {
    @Test func initials() {
        #expect(ConnectionIcons.initials("Sample (Docker)") == "SD")
        #expect(ConnectionIcons.initials("staging on ep-crimson-field") == "SE")
        #expect(ConnectionIcons.initials("andromeda") == "AN")
        #expect(ConnectionIcons.initials("Andromeda cloud staging") == "AC")
    }

    @Test func iconsFallBackToInitials() {
        #expect(ConnectionIcons.validated("leaf.fill") == "leaf.fill")
        #expect(ConnectionIcons.validated("not.a.real.symbol") == nil)
        #expect(ConnectionIcons.validated(nil) == nil)
        #expect(ConnectionIcons.pack.allSatisfy { ConnectionIcons.validated($0) != nil })
        #expect(Set(ConnectionIcons.pack).count == ConnectionIcons.pack.count)
    }
}
