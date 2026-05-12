func twoLetterPermutations(_ string: String) -> [String] {
    let chars = Array(string)
    var result: [String] = []
    for i in 0..<chars.count {
        for j in 0..<chars.count {
            if i != j {
                result.append(String([chars[i], chars[j]]))
            }
        }
    }
    return result
}
