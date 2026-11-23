import XCTest
@testable import TVVoice

final class GrammarTests: XCTestCase {
    let grammar = GrammarInterpreter()

    func canonical(_ text: String) -> String {
        grammar.interpret(text)?.canonical ?? "none"
    }

    func testCoreCommandsFromThePlan() {
        XCTAssertEqual(canonical("volume up"), "volume:up:1")
        XCTAssertEqual(canonical("mute"), "volume:mute")
        XCTAssertEqual(canonical("open Netflix"), "launch:netflix")
        XCTAssertEqual(canonical("go back"), "key:back")
        XCTAssertEqual(canonical("pause"), "key:pause")
        XCTAssertEqual(canonical("channel 7"), "channel:7")
    }

    func testAmountsAndRepeats() {
        XCTAssertEqual(canonical("turn it up three"), "volume:up:3")
        XCTAssertEqual(canonical("set the volume to twenty"), "volume:set:20")
        XCTAssertEqual(canonical("down twice"), "key:down*2")
        XCTAssertEqual(canonical("move right 3 times"), "key:right*3")
        XCTAssertEqual(canonical("seven point one"), "none")
        XCTAssertEqual(canonical("channel seven point one"), "channel:7.1")
    }

    func testSeekAndInputs() {
        XCTAssertEqual(canonical("skip ahead 30 seconds"), "seek:30")
        XCTAssertEqual(canonical("go back two minutes"), "seek:-120")
        XCTAssertEqual(canonical("switch to hdmi two"), "input:hdmi2")
        XCTAssertEqual(canonical("change input"), "input:next")
    }

    func testTypingKeepsOriginalCase() {
        XCTAssertEqual(canonical("type Stranger Things"), "type:Stranger Things")
        XCTAssertEqual(canonical("type in hello"), "type:hello")
    }

    func testRecognitionErrorsAndFillers() {
        XCTAssertEqual(canonical("um open net flix please"), "launch:netflix")
        XCTAssertEqual(canonical("hey launch you tube"), "launch:youtube")
        XCTAssertEqual(canonical("what's the weather"), "none")
    }
}

final class AppCatalogTests: XCTestCase {
    func testAliasesAndFuzzyMatch() {
        let catalog = AppCatalog.standard
        XCTAssertEqual(catalog.match("hbo max").entry?.id, "max")
        XCTAssertEqual(catalog.match("netflics").entry?.id, "netflix")
        XCTAssertNil(catalog.match("zzzz").entry)
    }

    func testInstalledAppsAreAddedAndPreferred() {
        let catalog = AppCatalog.standard.adding(installed: [AppEntry(id: "tvos.com.example.zoo", name: "Zoo Planet")])
        XCTAssertEqual(GrammarInterpreter().interpret("open zoo planet", context: VoiceContext(catalog: catalog))?.canonical,
                       "launch:tvos.com.example.zoo")
    }

    func testVocabularyBiasIncludesAppsAndCommands() {
        let strings = VoiceVocabulary.contextualStrings(catalog: .standard)
        XCTAssertTrue(strings.contains("Netflix"))
        XCTAssertTrue(strings.contains("volume up"))
        XCTAssertLessThanOrEqual(strings.count, 100)
    }
}

final class SearchTests: XCTestCase {
    let search = ContentSearchInterpreter()

    func testExplicitSearch() {
        XCTAssertEqual(search.interpretExplicit("find Severance")?.canonical, "search:severance")
        XCTAssertEqual(search.interpretExplicit("play stranger things on netflix")?.canonical, "search:stranger things@netflix")
        XCTAssertEqual(search.interpretExplicit("search youtube for cat videos")?.canonical, "search:cat videos@youtube")
    }

    func testVagueRequestsWaitForTheModel() {
        XCTAssertNil(search.interpretExplicit("put on something funny"))
        XCTAssertEqual(search.interpretFallback("put on something funny")?.canonical, "search:comedy")
    }

    func testNoSearchSupportFallsBackToLaunchingTheApp() {
        let context = VoiceContext(supportsSearch: false)
        XCTAssertEqual(search.interpretExplicit("play the bear on hulu", context: context)?.canonical, "launch:hulu")
    }
}
