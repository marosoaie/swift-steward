/// Why a run's command-line options don't parse, which ends the run with
/// status 2 before anything else happens.
enum OptionsError: Error, Equatable, CustomStringConvertible {
    case unknownOption(String)
    case unexpectedArgument(String)
    case missingValue(String)
    case invalidPullRequest(String)

    var description: String {
        switch self {
        case .unknownOption(let option): "Unknown option \(option)."
        case .unexpectedArgument(let argument): "Unexpected argument \(argument): the run takes options only."
        case .missingValue(let option): "\(option) needs a value."
        case .invalidPullRequest(let value): "--pull-request takes a pull request's number, not \(value)."
        }
    }
}
