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
}
#endif
