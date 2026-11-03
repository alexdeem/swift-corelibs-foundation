// This source file is part of the Swift.org open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

#if NS_FOUNDATION_ALLOWS_TESTABLE_IMPORT
#if canImport(SwiftFoundationNetworking) && !DEPLOYMENT_RUNTIME_OBJC
@testable import SwiftFoundationNetworking
#else
@testable import FoundationNetworking
#endif

final class TestURLSessionDownloadFile: XCTestCase {
    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    func test_creationFailurePreservesUnderlyingError() throws {
        let file = _DownloadFile(url: temporaryURL().appendingPathComponent("missing/download"))
        XCTAssertThrowsError(try file.open()) { error in
            let error = error as NSError
            XCTAssertEqual(error.domain, NSURLErrorDomain)
            XCTAssertEqual(error.code, NSURLErrorCannotCreateFile)
            let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError
            XCTAssertNotNil(underlying)
            XCTAssertNotEqual(underlying?.domain, NSURLErrorDomain)
        }
    }

    func test_creationDoesNotOverwriteOrRemoveExistingFile() throws {
        let url = temporaryURL()
        let data = Data("existing file".utf8)
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let file = _DownloadFile(url: url)
        XCTAssertThrowsError(try file.open())
        file.discard()
        XCTAssertEqual(try Data(contentsOf: url), data)
    }

    func test_resetReplacesPreviousResponseAndFinishKeepsFile() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let file = _DownloadFile(url: url)
        try file.append(Data("a longer authentication failure response".utf8))
        try file.reset()
        try file.append(Data("success".utf8))
        try file.append(Data("!".utf8))
        XCTAssertEqual(try file.finish(), url)
        XCTAssertNil(file.fileHandle)
        file.discard()
        XCTAssertEqual(try Data(contentsOf: url), Data("success!".utf8))
    }

    func test_emptyDownload() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let file = _DownloadFile(url: url)
        XCTAssertEqual(try file.finish(), url)
        XCTAssertEqual(try Data(contentsOf: url), Data())
    }

    func test_discardRemovesPartialDownload() throws {
        let url = temporaryURL()
        let file = _DownloadFile(url: url)
        try file.append(Data("partial response".utf8))
        file.discard()
        XCTAssertNil(file.fileHandle)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func test_writeAndResetFailuresThrow() throws {
        let file = _DownloadFile(url: temporaryURL())
        try file.open()
        try XCTUnwrap(file.fileHandle).close()
        for operation in [{ try file.append(Data([1])) }, { try file.reset() }] {
            XCTAssertThrowsError(try operation()) { error in
                let error = error as NSError
                XCTAssertEqual(error.domain, NSURLErrorDomain)
                XCTAssertEqual(error.code, NSURLErrorCannotWriteToFile)
                XCTAssertNotNil(error.userInfo[NSUnderlyingErrorKey])
            }
        }
    }

    func test_creationFailureCompletesTask() throws {
        let url = try XCTUnwrap(URL(string: "http://example.com/download"))
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.downloadTask(with: url)
        let client = DownloadFileProtocolClient()
        let proto = _HTTPURLProtocol(task: task, cachedResponse: nil, client: client)
        proto.downloadFile = _DownloadFile(url: temporaryURL().appendingPathComponent("missing/download"))
        proto.startNewTransfer(with: URLRequest(url: url))
        XCTAssertEqual(client.errors.count, 1)
        XCTAssertEqual(client.errors.first?.code, NSURLErrorCannotCreateFile)
        XCTAssertEqual((task.error as NSError?)?.code, NSURLErrorCannotCreateFile)
        XCTAssertEqual(client.finishedCount, 0)
        guard case .taskCompleted = proto.internalState else {
            return XCTFail("Expected task completion after file creation failed")
        }
    }

    func test_writeFailureAbortsBeforeReportingFilesystemError() throws {
        let url = try XCTUnwrap(URL(string: "http://example.com/download"))
        let client = DownloadFileProtocolClient()
        let proto = _HTTPURLProtocol(request: URLRequest(url: url), cachedResponse: nil, client: client)
        let file = proto.downloadFile
        try file.open()
        try XCTUnwrap(file.fileHandle).close()
        var state = _NativeProtocol._TransferState(url: url, bodyDataDrain: .toFile(file))
        state.response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)
        proto.internalState = .transferInProgress(state)

        guard case .abort = proto.didReceive(data: Data([1])) else {
            return XCTFail("Expected the write failure to abort the transfer")
        }
        XCTAssertTrue(client.errors.isEmpty, "Failure must be reported after the libcurl callback returns")
        proto.transferCompleted(withError: NSError(domain: NSURLErrorDomain, code: NSURLErrorUnknown))
        XCTAssertEqual(client.errors.count, 1)
        let error = try XCTUnwrap(client.errors.first)
        XCTAssertEqual(error.code, NSURLErrorCannotWriteToFile)
        let fileError = try XCTUnwrap(error.userInfo[NSUnderlyingErrorKey] as? NSError)
        XCTAssertNotNil(fileError.userInfo[NSUnderlyingErrorKey])
        XCTAssertEqual(client.finishedCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.url.path))
    }

    func test_finishFailureDoesNotReportSuccess() throws {
        let url = try XCTUnwrap(URL(string: "http://example.com/download"))
        let client = DownloadFileProtocolClient()
        let proto = _HTTPURLProtocol(request: URLRequest(url: url), cachedResponse: nil, client: client)
        proto.downloadFile = _DownloadFile(url: temporaryURL().appendingPathComponent("missing/download"))
        let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil))
        proto.internalState = .transferCompleted(response: response, bodyDataDrain: .toFile(proto.downloadFile))
        proto.completeTask()
        XCTAssertEqual(client.errors.count, 1)
        XCTAssertEqual(client.finishedCount, 0)
        XCTAssertNil(proto.properties[.temporaryFileURL])
    }
}

// These tests drive the protocol synchronously without starting a network transfer.
private final class DownloadFileProtocolClient: NSObject, URLProtocolClient, @unchecked Sendable {
    var errors: [NSError] = []
    var finishedCount = 0

    func urlProtocol(_ protocol: URLProtocol, didFailWithError error: Error) { errors.append(error as NSError) }
    func urlProtocolDidFinishLoading(_ protocol: URLProtocol) { finishedCount += 1 }
    func urlProtocol(_ protocol: URLProtocol, didLoad data: Data) {}
    func urlProtocol(_ protocol: URLProtocol, didReceive response: URLResponse, cacheStoragePolicy policy: URLCache.StoragePolicy) {}
    func urlProtocol(_ protocol: URLProtocol, wasRedirectedTo request: URLRequest, redirectResponse: URLResponse) {}
    func urlProtocol(_ protocol: URLProtocol, cachedResponseIsValid cachedResponse: CachedURLResponse) {}
    func urlProtocol(_ protocol: URLProtocol, didReceive challenge: URLAuthenticationChallenge) {}
    func urlProtocol(_ protocol: URLProtocol, didCancel challenge: URLAuthenticationChallenge) {}
}
#endif
