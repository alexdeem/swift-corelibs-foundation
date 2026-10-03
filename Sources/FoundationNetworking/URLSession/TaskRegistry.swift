// Foundation/URLSession/TaskRegistry.swift - URLSession & libcurl
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2016 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
// -----------------------------------------------------------------------------
///
/// These are libcurl helpers for the URLSession API code.
/// - SeeAlso: https://curl.haxx.se/libcurl/c/
/// - SeeAlso: URLSession.swift
///
// -----------------------------------------------------------------------------

#if os(macOS) || os(iOS) || os(watchOS) || os(tvOS)
import SwiftFoundation
#else
import Foundation
#endif

import Dispatch

extension URLSession {
    /// This helper class keeps track of all tasks.
    ///
    /// Each `URLSession` has a `TaskRegistry` for its running tasks.
    ///
    /// - Note: This must **only** be accessed on the owning session's work queue.
    class _TaskRegistry {
        fileprivate var tasks: [Int: URLSessionTask] = [:]
        fileprivate var tasksFinishedCallback: (() -> Void)?
    }
}

extension URLSession._TaskRegistry {
    /// Add a task
    ///
    /// - Note: This must **only** be accessed on the owning session's work queue.
    func add(_ task: URLSessionTask) {
        let identifier = task.taskIdentifier
        guard identifier != 0 else { fatalError("Invalid task identifier") }
        guard tasks.index(forKey: identifier) == nil else {
            if tasks[identifier] === task {
                fatalError("Trying to re-insert a task that's already in the registry.")
            } else {
                fatalError("Trying to insert a task, but a different task with the same identifier is already in the registry.")
            }
        }
        tasks[identifier] = task
    }
    /// Remove a task
    ///
    /// - Note: This must **only** be accessed on the owning session's work queue.
    func remove(_ task: URLSessionTask) {
        let identifier = task.taskIdentifier
        guard identifier != 0 else { fatalError("Invalid task identifier") }
        guard let tasksIdx = tasks.index(forKey: identifier) else {
            fatalError("Trying to remove task, but it's not in the registry.")
        }
        tasks.remove(at: tasksIdx)

        guard let allTasksFinished = tasksFinishedCallback else { return }
        if self.isEmpty {
            allTasksFinished()
        }
    }

    func notify(on tasksCompletion: @escaping () -> Void) {
        tasksFinishedCallback = tasksCompletion
    }

    var isEmpty: Bool {
        return tasks.isEmpty
    }
    
    var allTasks: [URLSessionTask] {
        return tasks.map { $0.value }
    }
}
