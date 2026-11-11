import Foundation

/// Сбои транспорта в терминах ядра. Приложение переводит в них ошибки URLSession.
public enum TransportError: Error, Equatable, Sendable {
    /// Пауза без байтов дольше допустимого.
    case timedOut
    /// Система сообщила, что сети нет.
    case offline
    /// Обрыв, сброс соединения и прочее.
    case failed(String)
}

/// Ответ на GET: статус и заголовки приходят сразу, тело отдаётся кусками по мере поступления.
public struct TransportResponse: Sendable {
    public let status: Int
    /// Ключи в нижнем регистре.
    public let headers: [String: String]
    public let body: AsyncThrowingStream<Data, Error>

    public init(status: Int, headers: [String: String], body: AsyncThrowingStream<Data, Error>) {
        self.status = status
        var lower: [String: String] = [:]
        for (k, v) in headers { lower[k.lowercased()] = v }
        self.headers = lower
        self.body = body
    }

    public func header(_ name: String) -> String? {
        return headers[name.lowercased()]
    }
}

/// Как ядро ходит за файлом. В приложении это URLSession, в тестах сервер-двойник в памяти.
public protocol Transport: Sendable {
    /// Бросает `TransportError` (или `CancellationError`, если отменили задачу).
    func get(_ url: URL, headers: [String: String]) async throws -> TransportResponse
}
