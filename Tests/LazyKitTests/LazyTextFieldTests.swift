import Testing

@testable import LazyKit

struct LazyTextFieldTests {
    @Test("default configuration exposes the documented baseline")
    func defaultConfigurationHasExpectedLayoutValues() {
        let configuration = LazyTextFieldConfiguration.default

        #expect(configuration.minimumNumberOfLines == 1)
        #expect(configuration.maximumNumberOfLines == nil)
        #expect(configuration.characterLimit == nil)
        #expect(configuration.accessibilityIdentifier == "lazy_text_field")
        #expect(configuration.placeholderAccessibilityIdentifier == "lazy_text_field_placeholder")
    }

    @Test("configuration values can be customized")
    func configurationCanBeCustomized() {
        var configuration = LazyTextFieldConfiguration.default
        configuration.minimumNumberOfLines = 2
        configuration.maximumNumberOfLines = 4
        configuration.characterLimit = 20
        configuration.accessibilityIdentifier = "custom_field"

        #expect(configuration.minimumNumberOfLines == 2)
        #expect(configuration.maximumNumberOfLines == 4)
        #expect(configuration.characterLimit == 20)
        #expect(configuration.accessibilityIdentifier == "custom_field")
    }

    @Test("the character limit clamps repeated over-limit edits")
    func characterLimitClampsRepeatedOverflow() {
        #expect(limitedText("abcd", characterLimit: 3) == "abc")
        #expect(limitedText("abcde", characterLimit: 3) == "abc")
    }

    @Test("the character limit counts Unicode grapheme clusters")
    func characterLimitClampsUnicodeWithoutSplittingCharacters() {
        #expect(limitedText("A👩‍🚀B", characterLimit: 2) == "A👩‍🚀")
    }

    @Test("nil and non-positive limits leave values unchanged")
    func disabledCharacterLimitsLeaveValuesUnchanged() {
        #expect(limitedText("A long note", characterLimit: nil) == "A long note")
        #expect(limitedText("A long note", characterLimit: 0) == "A long note")
        #expect(limitedText("A long note", characterLimit: -1) == "A long note")
    }

    @Test("values within the character limit remain unchanged")
    func characterLimitLeavesAcceptedValuesUnchanged() {
        #expect(limitedText("abc", characterLimit: 3) == "abc")
    }
}
