func isStringHasDuplicates(string: String) -> Bool {
    return string.count != Set(string).count
}
