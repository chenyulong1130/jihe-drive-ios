import Foundation

/// 签到等 H5 通道（与 Flutter H5ApiClient 对齐，不可复用 App 端 appId）
enum H5Client {
    static let host = "https://h5.zeehoev.com"
    private static let appId = "AiTXmBrm"
    private static let appSecret = "70c2c7458ab88ca9504ad0521f170075bc91f2f7"
    private static let serverName = "SMART"

    static var mineQuery: [String: String] { ["server_name": serverName] }

    static func get(_ path: String, query: [String: String] = mineQuery) async throws -> [String: Any] {
        try await send("GET", path: path, query: query, body: nil)
    }

    static func post(_ path: String, query: [String: String] = mineQuery, body: [String: Any]? = nil) async throws -> [String: Any] {
        try await send("POST", path: path, query: query, body: body)
    }

    private static func send(
        _ method: String,
        path: String,
        query: [String: String],
        body: [String: Any]?
    ) async throws -> [String: Any] {
        var components = URLComponents(string: host + path)!
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components.url else {
            throw ZeehoError.network("无效地址")
        }

        let queryString = components.percentEncodedQuery ?? ""
        // H5 签名 raw 不含 body
        let sign = h5Sign(query: queryString)
        let bodyData: Data?
        if let body {
            bodyData = try JSONSerialization.data(withJSONObject: body)
        } else {
            bodyData = nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 15
        request.httpBody = bodyData
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("zh-CN,zh-Hans;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue(sign.sign, forHTTPHeaderField: "Cfmoto-X-Sign")
        request.setValue(sign.appParam, forHTTPHeaderField: "Cfmoto-X-Param")
        request.setValue("0", forHTTPHeaderField: "Cfmoto-X-Sign-Type")
        request.setValue(sign.sign, forHTTPHeaderField: "signature")
        request.setValue(appId, forHTTPHeaderField: "appid")
        request.setValue(sign.timestamp, forHTTPHeaderField: "timestamp")
        request.setValue(sign.nonce, forHTTPHeaderField: "nonce")
        request.setValue(ZeehoSigner.appInfoHeader(), forHTTPHeaderField: "x-app-info")
        if bodyData != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let token = ZeehoClient.shared.token, !token.isEmpty {
            let bare = token.replacingOccurrences(
                of: #"^[bB]earer\s+"#,
                with: "",
                options: .regularExpression
            )
            request.setValue("bearer \(bare)", forHTTPHeaderField: "Authorization")
        }
        if let userId = ZeehoClient.shared.userId, !userId.isEmpty {
            request.setValue(userId, forHTTPHeaderField: "user_id")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ZeehoError.network("无响应")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ZeehoError.decoding("H5 响应解析失败（\(http.statusCode)）")
        }
        let code = ZeehoClient.codeString(json["code"])
        if code == "401" {
            throw ZeehoError.unauthorized
        }
        return json
    }

    private static func h5Sign(query: String) -> ZeehoSigner.Params {
        let timestamp = String(Int(Date().timeIntervalSince1970 * 1000))
        let nonce = ZeehoSigner.uuid()
        let appParam = "appId=\(appId)&nonce=\(nonce)&timestamp=\(timestamp)"
        let raw = query + appParam + appSecret
        return ZeehoSigner.Params(
            sign: ZeehoSigner.digest(raw),
            appParam: appParam,
            timestamp: timestamp,
            nonce: nonce
        )
    }
}
