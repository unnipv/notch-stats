import Foundation

func jsonObject(_ string: String) -> [String: Any]? {
    guard let data = string.data(using: .utf8) else { return nil }
    return jsonObject(data)
}

func jsonObject(_ data: Data) -> [String: Any]? {
    guard let any = try? JSONSerialization.jsonObject(with: data) else { return nil }
    return any as? [String: Any]
}

/// Last path component, falling back to the whole path.
func projectName(_ directory: String) -> String {
    let name = (directory as NSString).lastPathComponent
    return name.isEmpty ? directory : name
}

/// "deepseek/deepseek-v4.1-flash" -> "deepseek-v4.1-flash"
func shortModel(_ model: String?) -> String? {
    guard let model else { return nil }
    return model.split(separator: "/").last.map(String.init) ?? model
}
