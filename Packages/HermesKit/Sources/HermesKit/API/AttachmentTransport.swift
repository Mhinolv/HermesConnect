import Foundation

/// `image.attach_bytes` params (`methods_prompt.py:1028-1056`).
public struct ImageAttachBytesParams: Encodable, Sendable, Equatable {
    public var sessionId: String
    public var contentBase64: String
    public var filename: String?

    private enum CodingKeys: String, CodingKey {
        case sessionId = "session_id", contentBase64 = "content_base64", filename
    }
}

/// `file.attach` params (`methods_prompt.py:1117-1137`).
public struct FileAttachParams: Encodable, Sendable, Equatable {
    public var sessionId: String
    public var dataURL: String
    public var name: String

    private enum CodingKeys: String, CodingKey { case sessionId = "session_id", dataURL = "data_url", name }
}

/// `pdf.attach` params (`methods_prompt.py:1059-1114`).
public struct PDFAttachParams: Encodable, Sendable, Equatable {
    public var sessionId: String
    public var contentBase64: String
    public var filename: String
    public var firstPage: Int?
    public var lastPage: Int?

    private enum CodingKeys: String, CodingKey {
        case sessionId = "session_id", contentBase64 = "content_base64", filename
        case firstPage = "first_page", lastPage = "last_page"
    }
}

/// The part of an attach result that the app reads.
public struct AttachResult: Decodable, Sendable, Equatable {
    public var attached: Bool?
    /// `file.attach`: the `@file:` ref for the prompt text.
    public var refText: String?

    private enum CodingKeys: String, CodingKey { case attached, refText = "ref_text" }
}

extension GatewayClient {
    /// `image.attach_bytes`. The image goes with the next `prompt.submit`.
    public func attachImageBytes(_ params: ImageAttachBytesParams) async throws -> AttachResult {
        try await call("image.attach_bytes", params: params)
    }

    /// `file.attach` with a `data_url`. Put `ref_text` first in the prompt text.
    public func attachFile(_ params: FileAttachParams) async throws -> AttachResult {
        try await call("file.attach", params: params)
    }

    /// `pdf.attach`. The server renders the pages to images (`pdftoppm`, else error 5028).
    public func attachPDF(_ params: PDFAttachParams) async throws -> AttachResult {
        try await call("pdf.attach", params: params)
    }
}

/// What the attachment send flow needs from the gateway (issue #8). `GatewayClient` and
/// `LiveChatTransport` conform. A chat transport without it fails each attachment ("Not Delivered").
public protocol AttachmentTransport: Sendable {
    func attachImage(sessionId: String, data: Data, filename: String) async throws
    /// Returns the `ref_text` for the prompt.
    func attachFile(sessionId: String, data: Data, name: String, mimeType: String) async throws -> String?
    func attachPDF(sessionId: String, data: Data, filename: String, lastPage: Int?) async throws
}

/// `pdf.attach` error when the server has no `pdftoppm` (docs/hermes-protocol.md 3.8).
public let pdfRendererMissingCode = 5028

extension GatewayClient: AttachmentTransport {
    public func attachImage(sessionId: String, data: Data, filename: String) async throws {
        let result = try await attachImageBytes(ImageAttachBytesParams(
            sessionId: sessionId, contentBase64: data.base64EncodedString(), filename: filename))
        guard result.attached != false else { throw GatewayError.invalidResponse(method: "image.attach_bytes") }
    }

    public func attachFile(sessionId: String, data: Data, name: String, mimeType: String) async throws -> String? {
        let result = try await attachFile(FileAttachParams(
            sessionId: sessionId, dataURL: AttachmentPayload.dataURL(data, mimeType: mimeType), name: name))
        guard result.attached != false else { throw GatewayError.invalidResponse(method: "file.attach") }
        return result.refText
    }

    public func attachPDF(sessionId: String, data: Data, filename: String, lastPage: Int?) async throws {
        let result = try await attachPDF(PDFAttachParams(
            sessionId: sessionId, contentBase64: data.base64EncodedString(), filename: filename,
            firstPage: lastPage == nil ? nil : 1, lastPage: lastPage))
        guard result.attached != false else { throw GatewayError.invalidResponse(method: "pdf.attach") }
    }
}

extension LiveChatTransport: AttachmentTransport {
    public func attachImage(sessionId: String, data: Data, filename: String) async throws {
        try await readyClient().attachImage(sessionId: sessionId, data: data, filename: filename)
    }

    public func attachFile(sessionId: String, data: Data, name: String, mimeType: String) async throws -> String? {
        try await readyClient().attachFile(sessionId: sessionId, data: data, name: name, mimeType: mimeType)
    }

    public func attachPDF(sessionId: String, data: Data, filename: String, lastPage: Int?) async throws {
        try await readyClient().attachPDF(sessionId: sessionId, data: data, filename: filename, lastPage: lastPage)
    }
}
