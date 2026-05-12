func prefixOfStringToInt(string: String) -> Int? {
    return Int(string.prefix(while: { $0.isNumber }))
}

func stringToIntViaFilter(string: String) -> Int? {
    return Int(string.filter { $0.isNumber })
}

//Likely use this one
func stringToIntViaFirstMatch(string: String) -> Int? {
    return Int(string.firstMatch(of: /\d+/)?.output ?? "")
}
