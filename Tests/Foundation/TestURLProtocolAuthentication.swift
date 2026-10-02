// This source file is part of the Swift.org open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//

import Synchronization

private final class AuthenticationProbeProtocol: URLProtocol {
    static let decisions = Mutex<[String]>([])

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "authentication-probe.invalid"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        if url.path == "/unauthorized" {
            let response = HTTPURLResponse(url: url, statusCode: 401, httpVersion: "HTTP/1.1",
                                           headerFields: ["WWW-Authenticate": "Basic realm=\"probe\""])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("denied".utf8))
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let space = URLProtectionSpace(host: url.host!, port: 80, protocol: "http", realm: "probe",
                                       authenticationMethod: NSURLAuthenticationMethodHTTPBasic)
        let sender = AuthenticationProbeSender(self)
        let challenge = URLAuthenticationChallenge(protectionSpace: space, proposedCredential: nil,
                                                   previousFailureCount: 0, failureResponse: nil,
                                                   error: nil, sender: sender)
        client?.urlProtocol(self, didReceive: challenge)
    }

    override func stopLoading() {}
}

private final class AuthenticationProbeSender: NSObject, URLAuthenticationChallengeSender, @unchecked Sendable {
    private weak var owner: AuthenticationProbeProtocol?

    init(_ owner: AuthenticationProbeProtocol) { self.owner = owner }

    private func finish(_ decision: String) {
        AuthenticationProbeProtocol.decisions.withLock { $0.append(decision) }
        guard let owner, let url = owner.request.url else { return }
        if decision == "cancel" {
            owner.client?.urlProtocol(owner, didFailWithError: URLError(.cancelled))
            return
        }
        let authorized = decision == "use"
        let response = HTTPURLResponse(url: url, statusCode: authorized ? 200 : 401,
                                       httpVersion: "HTTP/1.1", headerFields: nil)!
        owner.client?.urlProtocol(owner, didReceive: response, cacheStoragePolicy: .notAllowed)
        owner.client?.urlProtocol(owner, didLoad: Data((authorized ? "authorized" : "denied").utf8))
        owner.client?.urlProtocolDidFinishLoading(owner)
    }

    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {
        finish(credential.user == "probe-user" ? "use" : "wrongCredential")
    }

    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) { finish("withoutCredential") }
    func cancel(_ challenge: URLAuthenticationChallenge) { finish("cancel") }
    func performDefaultHandling(for challenge: URLAuthenticationChallenge) { finish("default") }
    func rejectProtectionSpaceAndContinue(with challenge: URLAuthenticationChallenge) { finish("reject") }
}

private final class AuthenticationProbeDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let mode: String

    init(_ mode: String) { self.mode = mode }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @Sendable @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        switch mode {
        case "use":
            completionHandler(.useCredential, URLCredential(user: "probe-user", password: "probe-password", persistence: .none))
        case "reject": completionHandler(.rejectProtectionSpace, nil)
        case "cancel": completionHandler(.cancelAuthenticationChallenge, nil)
        default: completionHandler(.performDefaultHandling, nil)
        }
    }
}

final class TestURLProtocolAuthentication: XCTestCase {
    func test_customUnauthorizedResponseDoesNotInventChallenge() {
        AuthenticationProbeProtocol.decisions.withLock { $0 = [] }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AuthenticationProbeProtocol.self]
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: AuthenticationProbeDelegate("use"), delegateQueue: nil)
        let done = expectation(description: "custom 401")
        session.dataTask(with: URL(string: "http://authentication-probe.invalid/unauthorized")!) { data, response, error in
            XCTAssertNil(error)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 401)
            XCTAssertEqual(data, Data("denied".utf8))
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 5)
        XCTAssertEqual(AuthenticationProbeProtocol.decisions.withLock { $0 }, [])
        session.invalidateAndCancel()
    }

    func test_customChallengeReturnsEachDecisionToItsSender() {
        for mode in ["use", "default", "reject", "cancel", "noDelegate"] {
            AuthenticationProbeProtocol.decisions.withLock { $0 = [] }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [AuthenticationProbeProtocol.self]
            configuration.urlCache = nil
            configuration.urlCredentialStorage = nil
            configuration.timeoutIntervalForRequest = 3
            let delegate = mode == "noDelegate" ? nil : AuthenticationProbeDelegate(mode)
            let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
            let done = expectation(description: mode)
            let url = URL(string: "http://authentication-probe.invalid/challenge")!
            session.dataTask(with: url) { data, response, error in
                if mode == "cancel" {
                    XCTAssertEqual((error as? URLError)?.code, .cancelled)
                } else {
                    XCTAssertNil(error)
                    XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, mode == "use" ? 200 : 401)
                    XCTAssertEqual(data, Data((mode == "use" ? "authorized" : "denied").utf8))
                }
                done.fulfill()
            }.resume()
            wait(for: [done], timeout: 5)
            XCTAssertEqual(AuthenticationProbeProtocol.decisions.withLock { $0 },
                           [mode == "noDelegate" ? "default" : mode])
            session.invalidateAndCancel()
        }
    }
}
