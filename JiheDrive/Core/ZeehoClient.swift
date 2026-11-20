import Foundation

enum ZeehoError: LocalizedError {
    case network(String)
    case decoding(String)
    case server(code: String, message: String)
    case unauthorized

    var errorDescription: String? {
        switch self {
        case .network(let message), .decoding(let message):
            return message
        case .server(_, let message):
            return message
        case .unauthorized:
            return "登录已过期，请重新登录"
        }
    }
}

final class ZeehoClient {
    static let shared = ZeehoClient()
    static let host = "https://tapi.zeehoev.com"

    private let session: URLSession
    private let store: KeychainStore

    init(session: URLSession = .shared, store: KeychainStore = .shared) {
        self.session = session
        self.store = store
    }

    var token: String? {
        get { store.value(for: .token) }
        set { store.set(newValue, for: .token) }
    }

    var userId: String? {
        get { store.value(for: .userId) }
        set { store.set(newValue, for: .userId) }
    }

    var isLoggedIn: Bool {
        !(token ?? "").isEmpty
    }

    func clearSession() {
        token = nil
        userId = nil
    }

    // MARK: - Verbs

    func get(_ path: String, query: [String: String] = [:]) async throws -> [String: Any] {
        try await send("GET", path, query: query, body: nil, isLogin: false)
    }

    func post(_ path: String, body: [String: Any]? = nil, query: [String: String] = [:]) async throws -> [String: Any] {
        try await send("POST", path, query: query, body: body ?? [:], isLogin: false)
    }

    func put(_ path: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        try await send("PUT", path, query: [:], body: body ?? [:], isLogin: false)
    }

    func delete(_ path: String) async throws -> [String: Any] {
        try await send("DELETE", path, query: [:], body: nil, isLogin: false)
    }

    /// multipart 按字段顺序交错上传（仪表壁纸 save 接口依赖顺序）
    func postMultipartOrdered(
        path: String,
        parts: [MultipartPart]
    ) async throws -> [String: Any] {
        let (url, queryString) = Self.makeURL(path: path, query: [:])
        // 与 Flutter 一致：multipart 签名不带 body 原文
        let sign = ZeehoSigner.sign(query: queryString, bodyJSON: "")
        let boundary = "----Zeeho\(Int(Date().timeIntervalSince1970 * 1000))"

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("zh-CN", forHTTPHeaderField: "Accept-Language")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("2", forHTTPHeaderField: "interfaceversion")
        request.setValue(sign.sign, forHTTPHeaderField: "Cfmoto-X-Sign")
        request.setValue(sign.appParam, forHTTPHeaderField: "Cfmoto-X-Param")
        request.setValue("0", forHTTPHeaderField: "Cfmoto-X-Sign-Type")
        request.setValue(sign.sign, forHTTPHeaderField: "signature")
        request.setValue(ZeehoSigner.appId, forHTTPHeaderField: "appid")
        request.setValue(sign.timestamp, forHTTPHeaderField: "timestamp")
        request.setValue(sign.nonce, forHTTPHeaderField: "nonce")
        request.setValue(ZeehoSigner.appInfoHeader(), forHTTPHeaderField: "x-app-info")
        if let token, !token.isEmpty {
            request.setValue("bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let userId, !userId.isEmpty {
            request.setValue(userId, forHTTPHeaderField: "user_id")
        }
        request.httpBody = Self.buildMultipartBody(boundary: boundary, parts: parts)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            if error is CancellationError { throw error }
            if let urlError = error as? URLError, urlError.code == .cancelled { throw CancellationError() }
            throw ZeehoError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw ZeehoError.decoding("无响应")
        }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else {
            throw ZeehoError.decoding("响应解析失败 (\(http.statusCode))")
        }
        let code = Self.codeString(dict["code"])
        if code == "401" {
            clearSession()
            throw ZeehoError.unauthorized
        }
        if http.statusCode >= 400 {
            throw ZeehoError.server(
                code: code,
                message: Self.errorText(dict) ?? "请求失败 (\(http.statusCode))"
            )
        }
        return dict
    }

    enum MultipartPart {
        case field(name: String, value: String)
        case file(name: String, filename: String, mime: String, data: Data)
    }

    private static func buildMultipartBody(boundary: String, parts: [MultipartPart]) -> Data {
        var body = Data()
        let crlf = "\r\n"
        for part in parts {
            body.append("--\(boundary)\(crlf)".data(using: .utf8)!)
            switch part {
            case .field(let name, let value):
                body.append("Content-Disposition: form-data; name=\"\(name)\"\(crlf)\(crlf)".data(using: .utf8)!)
                body.append(value.data(using: .utf8)!)
                body.append(crlf.data(using: .utf8)!)
            case .file(let name, let filename, let mime, let data):
                body.append(
                    "Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\(crlf)".data(using: .utf8)!
                )
                body.append("Content-Type: \(mime)\(crlf)\(crlf)".data(using: .utf8)!)
                body.append(data)
                body.append(crlf.data(using: .utf8)!)
            }
        }
        body.append("--\(boundary)--\(crlf)".data(using: .utf8)!)
        return body
    }

    func login(phone: String, code: String) async throws -> [String: Any] {
        let body: [String: Any] = [
            "authCode": code,
            "phone": phone,
            "city": "330100",
            "latitude": "30.274100",
            "longitude": "120.155100",
            "province": "",
            "referralCode": "",
        ]
        return try await send(
            "POST",
            "/v1.0/mine/cfmotoservermine/user/loginByPhone",
            query: [:],
            body: body,
            isLogin: true
        )
    }

    /// 发送短信验证码
    func requestAuthCode(phone: String) async throws -> [String: Any] {
        try await get("/v1.0/mine/cfmotoservermine/authCode/\(phone)")
    }

    // MARK: - Transport

    private func send(
        _ method: String,
        _ path: String,
        query: [String: String],
        body: [String: Any]?,
        isLogin: Bool
    ) async throws -> [String: Any] {
        let (url, queryString) = Self.makeURL(path: path, query: query)

        var bodyString = ""
        if (method == "POST" || method == "PUT"), let body {
            let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
            bodyString = String(data: data, encoding: .utf8) ?? "{}"
        }

        // 签名与发送必须使用同一串 body，服务端按收到的原文重算
        let sign = ZeehoSigner.sign(query: queryString, bodyJSON: bodyString)

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 15
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("zh-CN", forHTTPHeaderField: "Accept-Language")
        request.setValue("application/json;charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue("2", forHTTPHeaderField: "interfaceversion")
        request.setValue(sign.sign, forHTTPHeaderField: "Cfmoto-X-Sign")
        request.setValue(sign.appParam, forHTTPHeaderField: "Cfmoto-X-Param")
        request.setValue("0", forHTTPHeaderField: "Cfmoto-X-Sign-Type")
        request.setValue(sign.sign, forHTTPHeaderField: "signature")
        request.setValue(ZeehoSigner.appId, forHTTPHeaderField: "appid")
        request.setValue(sign.timestamp, forHTTPHeaderField: "timestamp")
        request.setValue(sign.nonce, forHTTPHeaderField: "nonce")
        request.setValue(ZeehoSigner.appInfoHeader(), forHTTPHeaderField: "x-app-info")

        if isLogin {
            request.setValue("Basic bWNrOjEyMzQ1Ng==", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        } else {
            if let token, !token.isEmpty {
                request.setValue("bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            if let userId, !userId.isEmpty {
                request.setValue(userId, forHTTPHeaderField: "user_id")
            }
        }

        if (method == "POST" || method == "PUT"), !bodyString.isEmpty {
            request.httpBody = Data(bodyString.utf8)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            // 上层切车/关页面会取消请求，原样抛出，避免被当成网络错误弹给用户
            if error is CancellationError { throw error }
            if let urlError = error as? URLError, urlError.code == .cancelled { throw CancellationError() }
            throw ZeehoError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw ZeehoError.decoding("无响应")
        }

        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else {
            throw ZeehoError.decoding("响应解析失败 (\(http.statusCode))")
        }

        let code = Self.codeString(dict["code"])
        if code == "401" {
            clearSession()
            throw ZeehoError.unauthorized
        }
        if http.statusCode >= 400 {
            throw ZeehoError.server(
                code: code,
                message: Self.errorText(dict) ?? "请求失败 (\(http.statusCode))"
            )
        }
        return dict
    }

    private static func makeURL(path: String, query: [String: String]) -> (URL, String) {
        var components = URLComponents(string: host + path)!
        guard !query.isEmpty else {
            return (components.url!, "")
        }
        let queryString = query.keys.sorted().map { key -> String in
            let value = query[key] ?? ""
            let encoded = value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? value
            return "\(key)=\(encoded)"
        }.joined(separator: "&")
        components.percentEncodedQuery = queryString
        return (components.url!, queryString)
    }

    static func codeString(_ raw: Any?) -> String {
        if let string = raw as? String { return string }
        if let number = raw as? NSNumber { return number.stringValue }
        return ""
    }

    /// 错误码 -> 用户可读文案，返回 nil 表示沿用服务端原文
    static func errorText(_ response: [String: Any]) -> String? {
        switch codeString(response["code"]) {
        case "30121":
            return "请求校验未通过，请更新到最新版本后重试"
        case "40005":
            return "该手机号今日获取验证码过于频繁，请明天再试"
        case "3006CM0002001":
            return "手机号格式有误，请检查后重试"
        case "3006CM0002002":
            return "验证码有误或已过期，请重新获取"
        case "401":
            return "登录已过期，请重新登录"
        default:
            break
        }
        let message = (response["message"] as? String) ?? ""
        if message.isEmpty || message == "success" || message == "permit error" {
            return nil
        }
        return message
    }
}
