// Copyright (c) 2023-2024 Tom Sutcliffe
// See LICENSE file for license information.

import XCTest
import Lua
import CLua
#if !LUASWIFT_NO_FOUNDATION
import Foundation
import CoreFoundation
#endif

fileprivate func dummyFn(_ L: LuaState!) -> CInt {
    return 0
}

class DeinitChecker {
    let deinitFn: () -> Void
    init(_ fn: @escaping () -> Void) {
        self.deinitFn = fn
    }
    deinit {
        deinitFn()
    }
}

class ClosableDeinitChecker : DeinitChecker, Closable {
    let closeFn: () -> Void
    init(deinitFn: @escaping () -> Void, closeFn: @escaping () -> Void) {
        self.closeFn = closeFn
        super.init(deinitFn)
    }
    func close() {
        closeFn()
    }
}


protocol TestMetatabledProtocol: PushableWithMetatable {
    func foo() -> String
}

extension TestMetatabledProtocol {
    static var metatable: Metatable<any TestMetatabledProtocol> {
        get {
            return Metatable(fields: [
                "foo": .memberfn { $0.foo() }
            ])
        }
    }
}

// Declare this here so we're testing that you can declare conformance via an extension
class test_PushableWithMetatable_Base {
    func foo() -> String { return "Base.foo" }
}

extension test_PushableWithMetatable_Base: PushableWithMetatable {
    static let metatable = Metatable<test_PushableWithMetatable_Base>(fields: [
        "foo": .memberfn { $0.foo() }
    ])
}

final class LuaTests: XCTestCase {

    var L: LuaState!

    override func setUp() {
        L = LuaState(libraries: [])
    }

    override func tearDown() {
        if let L {
            L.close()
        }
        L = nil
    }

    func test_constants() {
        // Since we redefine a bunch of enums to work around limitations of the bridge we really should check they have
        // the same values
        XCTAssertEqual(LuaType.nil.rawValue, LUA_TNIL)
        XCTAssertEqual(LuaType.boolean.rawValue, LUA_TBOOLEAN)
        XCTAssertEqual(LuaType.lightuserdata.rawValue, LUA_TLIGHTUSERDATA)
        XCTAssertEqual(LuaType.number.rawValue, LUA_TNUMBER)
        XCTAssertEqual(LuaType.string.rawValue, LUA_TSTRING)
        XCTAssertEqual(LuaType.table.rawValue, LUA_TTABLE)
        XCTAssertEqual(LuaType.function.rawValue, LUA_TFUNCTION)
        XCTAssertEqual(LuaType.userdata.rawValue, LUA_TUSERDATA)
        XCTAssertEqual(LuaType.thread.rawValue, LUA_TTHREAD)

        XCTAssertEqual(LuaState.GcWhat.stop.rawValue, LUA_GCSTOP)
        XCTAssertEqual(LuaState.GcWhat.restart.rawValue, LUA_GCRESTART)
        XCTAssertEqual(LuaState.GcWhat.collect.rawValue, LUA_GCCOLLECT)

        for t in LuaType.allCases {
            XCTAssertEqual(t.tostring(), String(cString: lua_typename(L, t.rawValue)))
        }
        XCTAssertEqual(LuaType.tostring(nil), String(cString: lua_typename(L, LUA_TNONE)))

        XCTAssertEqual(LuaState.ComparisonOp.eq.rawValue, LUA_OPEQ)
        XCTAssertEqual(LuaState.ComparisonOp.lt.rawValue, LUA_OPLT)
        XCTAssertEqual(LuaState.ComparisonOp.le.rawValue, LUA_OPLE)
    }

    let unsafeLibs = ["os", "io", "package", "debug"]

    func testSafeLibraries() {
        L.openLibraries(.safe)
        for lib in unsafeLibs {
            let t = L.getglobal(lib)
            XCTAssertEqual(t, .nil)
            L.pop()
        }
        XCTAssertEqual(L.gettop(), 0)
    }

    func testLibraries() {
        L.openLibraries(.all)
        for lib in unsafeLibs {
            let t = L.getglobal(lib)
            XCTAssertEqual(t, .table)
            L.pop()
        }
    }

    func test_pcall() throws {
        L.getglobal("type")
        L.push(123)
        try L.pcall(nargs: 1, nret: 1)
        XCTAssertEqual(L.gettop(), 1)
        XCTAssertEqual(L.tostring(-1), "number")
        L.pop()
    }

    func test_pcall_throw() throws {
        var expectedErr: LuaCallError? = nil
        do {
            L.getglobal("error")
            try L.pcall("Deliberate error", traceback: false)
        } catch let error as LuaCallError {
            expectedErr = error
        }
        // Put L out of scope here, to make sure err.description still works
        L.close()
        L = nil

        XCTAssertEqual(try XCTUnwrap(expectedErr).description, "Deliberate error")
    }

    // Test that I'm not going mad and closure scope and captured variables do behave the way I expect
    func test_closure_scope() {
        var closureDeinited = false
        do {
            let deinitChecker = DeinitChecker {
                closureDeinited = true
            }
            let _: LuaClosure = { L in
                // Force deinitChecker to be captured by the closure
                L.push(closure: deinitChecker.deinitFn)
                L.pop()
                return 0
            }
            XCTAssertFalse(closureDeinited)
        }
        XCTAssertTrue(closureDeinited)
    }

    func test_pcallk() throws {
        L.openLibraries([.coroutine])
        try L.load(string: """
            local nativefn = ...
            co = coroutine.create(function()
                local ret = nativefn()
                -- print("nativefn returned", ret)
                return ret + 1
            end)

            function thingThatCanYield()
                return coroutine.yield(123)
            end

            function resumeCo()
                return select(2, coroutine.resume(co, 456))
            end

            return coroutine.resume(co)
            """, name: "=test")
        var continuationYielded: Bool? = nil
        var continuationGarbageCollected = false
        do {
            let deinitChecker = DeinitChecker {
                continuationGarbageCollected = true
            }
            let c: LuaClosure = { L in
                L.push("string")
                L.getglobal("thingThatCanYield")
                return L.pcallk(nargs: 0, nret: 1, continuation: { L, status in
                    // Check the closure's stack has been preserved in the continuation
                    XCTAssertEqual(L.gettop(), 2)
                    XCTAssertEqual(L.tovalue(1), "string")
                    XCTAssertEqual(L.tovalue(2), 456) // The value from coroutine.resume(coa)
                    XCTAssertNil(status.error)

                    continuationYielded = status.yielded

                    // Force deinitChecker to be captured by the continuation
                    L.push(closure: deinitChecker.deinitFn)
                    L.pop()
                    
                    return 1 // Return the value thingThatCanYield yielded
                })
            }
            L.push(c) // becomes nativeFn
        }
        XCTAssertFalse(continuationGarbageCollected)
        try L.pcall(nargs: 1, nret: 2)
        // The continuation should not have been called yet because of the yield() call in thingThatCanYield
        XCTAssertEqual(continuationYielded, nil)
        XCTAssertEqual(L.toboolean(-2), true) // 1st result of coroutine.resume
        XCTAssertEqual(L.toint(-1), 123)

        L.collectgarbage() // This should not cause the continuation to be collected
        XCTAssertFalse(continuationGarbageCollected)

        L.getglobal("resumeCo")
        try L.pcall(nargs: 0, nret: 1)
        XCTAssertEqual(continuationYielded, true)
        XCTAssertEqual(L.tovalue(-1), 457)

        L.collectgarbage() // Give chance for the continuation to be collected
        XCTAssertTrue(continuationGarbageCollected)
    }

    // Test that the continuation for a yielded thread that is never resumed does eventually get GC'd once the thread
    // itself is collected
    func test_pcallk_continuationCollectedOnThreadCollection() throws {
        L.openLibraries([.coroutine])
        try L.load(string: """
            local nativefn = ...

            function thingThatCanYield(arg1, arg2)
                assert(arg1 == "abc")
                assert(arg2 == "def")
                return coroutine.yield()
            end

            co = coroutine.create(function()
                nativefn()
            end)
            return coroutine.resume(co)
            """, name: "=test")
        var continuationGarbageCollected = false
        do {
            let deinitChecker = DeinitChecker {
                continuationGarbageCollected = true
            }
            let c: LuaClosure = { L in
                L.getglobal("thingThatCanYield")
                L.push("abc")
                L.push("def")
                return L.pcallk(nargs: 2, nret: 0, continuation: { L, status in
                    // Force deinitChecker to be captured by the continuation
                    L.push(closure: deinitChecker.deinitFn)
                    XCTFail("Continuation should not be called")
                    return 0
                })
            }
            L.push(c) // becomes nativeFn
        }
        try L.pcall(nargs: 1, nret: 0)
        XCTAssertFalse(continuationGarbageCollected)
        XCTAssertEqual(L.gettop(), 0)
        L.collectgarbage()
        // Still won't have been collected because it's not been called, and there's still the global co
        XCTAssertFalse(continuationGarbageCollected)
        L.setglobal(name: "co", value: .nilValue)
        L.collectgarbage()
        XCTAssertTrue(continuationGarbageCollected)
    }

    func test_pcallk_error() throws {
        L.openLibraries([.coroutine])
        try L.load(string: """
            local nativefn = ...

            function thingThatErrors()
                error("NOPE")
            end

            co = coroutine.create(function()
                nativefn()
            end)
            return coroutine.resume(co)
            """, name: "=test")
        var continuationGarbageCollected = false
        var pcallkStatus: LuaPcallContinuationStatus? = nil
        do {
            let deinitChecker = DeinitChecker {
                continuationGarbageCollected = true
            }
            let c: LuaClosure = { L in
                L.getglobal("thingThatErrors")
                return L.pcallk(nargs: 0, nret: 0, continuation: { L, status in
                    pcallkStatus = status

                    // Force deinitChecker to be captured by the continuation
                    L.push(closure: deinitChecker.deinitFn)
                    L.pop()
                    return 0
                })
            }
            L.push(c) // becomes nativeFn
        }
        XCTAssertFalse(continuationGarbageCollected)
        try L.pcall(nargs: 1, nret: 0)

        XCTAssertFalse(try XCTUnwrap(pcallkStatus).yielded)
        XCTAssertNotNil(try XCTUnwrap(pcallkStatus).error)
        L.collectgarbage()
        XCTAssertTrue(continuationGarbageCollected)
    }

    func test_yield() throws {
        L.openLibraries([.coroutine])
        try L.load(string: """
            local nativefn = ...
            co = coroutine.create(function()
                return nativefn()
            end)
            return coroutine.resume(co)
            """)
        do {
            let c: LuaClosure = { L in
                L.push(123)
                return L.yield(nresults: 1)
            }
            L.push(c) // becomes nativeFn
        }
        try L.pcall(nargs: 1, nret: MultiRet)
        XCTAssertEqual(L.gettop(), 2)
        XCTAssertEqual(L.type(1), .boolean)
        XCTAssertTrue(L.toboolean(1))
        XCTAssertEqual(L.toint(2), 123)
    }

    func test_yieldk() throws {
        L.openLibraries([.coroutine])
        try L.load(string: """
            local nativefn = ...
            co = coroutine.create(function()
                return nativefn()
            end)
            function resumeCo()
                return select(2, coroutine.resume(co, 456, 789))
            end
            return coroutine.resume(co)
            """)
        var continuationCalled = false
        do {
            let c: LuaClosure = { L in
                L.push("string")
                L.push(123)
                return L.yield(nresults: 1, continuation: { L in
                    continuationCalled = true
                    XCTAssertEqual(L.gettop(), 3) // The existing stack, plus the two values from coroutine.resume()
                    XCTAssertEqual(L.tostring(1), "string")
                    XCTAssertEqual(L.toint(2), 456)
                    XCTAssertEqual(L.toint(3), 789)
                    L.pop()
                    return 1 // ie 456
                })
            }
            L.push(c) // becomes nativeFn
        }
        try L.pcall(nargs: 1, nret: MultiRet)
        XCTAssertEqual(L.gettop(), 2)
        XCTAssertEqual(L.type(1), .boolean)
        XCTAssertTrue(L.toboolean(1))
        XCTAssertEqual(L.toint(2), 123)
        XCTAssertFalse(continuationCalled)
        L.getglobal("resumeCo")
        try L.pcall(nargs: 0, nret: 1)
        XCTAssertTrue(continuationCalled)
        XCTAssertEqual(L.toint(-1), 456)
    }

    func test_thread() throws {
        let thread = L.newthread()
        thread.push({ L in
            XCTAssertEqual(L.tostring(1), "arg")
            L.push("yieldedval")
            return L.yield(nresults: 1) { L in
                XCTAssertEqual(L.gettop(), 2)
                XCTAssertEqual(L.tostring(1), "arg")
                XCTAssertEqual(L.tostring(2), "cont")
                L.push("done")
                return 1
            }
        })
        thread.push("arg")
        do {
            let (nresults, yielded, err) = thread.resume(from: nil, nargs: 1)
            XCTAssertEqual(nresults, 1)
            XCTAssertEqual(yielded, true)
            XCTAssertNil(err)
            if LUA_VERSION.is54orLater() {
                // Stack has 4 elements here - arg, 2 used internally by LuaSwift.yield(), and yieldedval
                XCTAssertEqual(thread.gettop(), 4)
                XCTAssertEqual(thread.tostring(1), "arg")
                XCTAssertEqual(thread.tostring(4), "yieldedval")
            } else {
                // Previous stack not retained
                XCTAssertEqual(thread.gettop(), 1)
                XCTAssertEqual(thread.tostring(1), "yieldedval")
            }
            thread.pop(nresults) // yieldedval
        }

        thread.push("cont")
        let (nresults, yielded, err) = thread.resume(from: nil, nargs: 1)
        XCTAssertEqual(nresults, 1)
        XCTAssertEqual(yielded, false)
        XCTAssertNil(err)
        XCTAssertEqual(thread.gettop(), 1)
        XCTAssertEqual(thread.tostring(1), "done")
        let closeErr = thread.closethread(from: nil)
        XCTAssertNil(closeErr)
        if LUA_VERSION.is54orLater() {
            XCTAssertEqual(thread.gettop(), 0)
        }
    }

    func test_thread_error() throws {
        let thread = L.newthread()
        thread.push({ L in
            throw L.error("doom")
        })
        thread.push("arg")
        // The docs on lua_resume and lua_closethread are a little unclear, but what _appears_ to happen if an
        // error is thrown from lua_resume, is that 2 copies of the error are left on the stack. The first we pop
        // in resume(), and the second is available to be popped by closethread().
        let (nresults, yielded, err) = thread.resume(from: nil, nargs: 1)
        XCTAssertEqual(nresults, 0)
        XCTAssertEqual(yielded, false)
        XCTAssertEqual(err?.errorString, "doom")
        XCTAssertEqual(thread.gettop(), 2)
        XCTAssertEqual(thread.tostring(1), "arg")
        XCTAssertEqual(thread.tostring(2), "doom")

        if LUA_VERSION.is54orLater() {
            let closeErr = thread.closethread(from: nil)
            XCTAssertEqual(closeErr?.errorString, "doom")
            XCTAssertEqual(thread.gettop(), 0) // closethread will have removed arg
        }
    }

    func test_istype() {
        L.push(1234) // 1
        L.push(12.34) // 2
        L.push(true) // 3
        L.pushnil() // 4

        XCTAssertTrue(L.isinteger(1))
        XCTAssertFalse(L.isinteger(2))
        XCTAssertFalse(L.isinteger(3))
        XCTAssertFalse(L.isnil(3))
        XCTAssertTrue(L.isnoneornil(4))
        XCTAssertTrue(L.isnil(4))
        XCTAssertFalse(L.isnone(4))
        XCTAssertTrue(L.isnone(5))
    }

    func test_toint() {
        L.push(1234) // 1
        L.push(true) // 2
        L.push("hello") // 3
        L.push(123.456) // 4
        L.pushnil() // 5
        L.push(function: dummyFn) // 6
        L.push(["a": 11, "b": 22, "c": 33]) // 7
        XCTAssertEqual(L.toint(1), 1234)
        XCTAssertEqual(L.toint(2), nil)
        XCTAssertEqual(L.toint(3), nil)
        XCTAssertEqual(L.toint(4), nil)
        XCTAssertEqual(L.toint(5), nil)
        XCTAssertEqual(L.toint(6), nil)
        XCTAssertEqual(L.toint(7, key: "b"), 22)
    }

    func test_tonumber() {
        L.push(1234) // 1
        L.push(true) // 2
        L.push("hello") // 3
        L.push(123.456) // 4
        L.pushnil() // 5
        L.push(function: dummyFn) // 6
        L.push("456.789") // 7
        L.push(["a": 11, "b": 22, "c": 33]) // 8
        let val: Double? = L.tonumber(1)
        XCTAssertEqual(val, 1234)
        XCTAssertEqual(L.tonumber(2), nil)
        XCTAssertEqual(L.tonumber(3), nil)
        XCTAssertEqual(L.tonumber(3, convert: true), nil)
        XCTAssertEqual(L.tonumber(4), 123.456)
        XCTAssertEqual(L.tonumber(5), nil)
        XCTAssertEqual(L.toint(6), nil)
        XCTAssertEqual(L.tonumber(7, convert: false), nil)
        XCTAssertEqual(L.tonumber(7, convert: true), 456.789)
        XCTAssertEqual(L.tonumber(8, key: "a"), 11.0)
    }

    func test_tobool() {
        L.push(1234) // 1
        L.push(true) // 2
        L.push(false) // 3
        L.pushnil() // 4
        L.push(function: dummyFn) // 5
        L.push(["a": false, "b": true]) // 6
        XCTAssertEqual(L.toboolean(1), true)
        XCTAssertEqual(L.toboolean(2), true)
        XCTAssertEqual(L.toboolean(3), false)
        XCTAssertEqual(L.toboolean(4), false)
        XCTAssertEqual(L.toboolean(5), true)
        XCTAssertEqual(L.toboolean(6, key: "a"), false)
        XCTAssertEqual(L.toboolean(6, key: "b"), true)
        XCTAssertEqual(L.toboolean(6, key: "c"), false)

        // Test that toboolean returns false if __index errored
        try! L.dostring("return setmetatable({}, { __index = function() error('NOPE') end })")
        XCTAssertEqual(L.toboolean(7, key: "anything"), false)
    }

    func test_tostring() {
        L.push("Hello")
        L.push("A ü†ƒ8 string")
        L.push(1234)

        XCTAssertEqual(L.tostring(1, convert: false), "Hello")
        XCTAssertEqual(L.tostring(2, convert: false), "A ü†ƒ8 string")
        XCTAssertEqual(L.tostring(3, convert: false), nil)
        XCTAssertEqual(L.tostring(3, convert: true), "1234")

        XCTAssertEqual(L.tostringUtf8(1, convert: false), "Hello")
        XCTAssertEqual(L.tostringUtf8(2, convert: false), "A ü†ƒ8 string")
        XCTAssertEqual(L.tostringUtf8(3, convert: false), nil)
        XCTAssertEqual(L.tostringUtf8(3, convert: true), "1234")

        L.push(utf8String: "A ü†ƒ8 string")
        XCTAssertTrue(L.rawequal(2, 4))
        L.pop()

#if !LUASWIFT_NO_FOUNDATION
        L.push(string: "A ü†ƒ8 string", encoding: .utf8)
        XCTAssertTrue(L.rawequal(2, 4))
        L.pop()

        L.push(string: "îsø", encoding: .isoLatin1)

        XCTAssertEqual(L.tostring(1, encoding: .utf8, convert: false), "Hello")
        XCTAssertEqual(L.tostring(2, encoding: .utf8, convert: false), "A ü†ƒ8 string")
        XCTAssertEqual(L.tostring(3, encoding: .utf8, convert: false), nil)
        XCTAssertEqual(L.tostring(3, encoding: .utf8, convert: true), "1234")
        XCTAssertEqual(L.tostring(4, convert: true), nil) // not valid in the default encoding (ie UTF-8)
        XCTAssertEqual(L.tostring(4, encoding: .isoLatin1, convert: false), "îsø")

        L.setDefaultStringEncoding(.stringEncoding(.isoLatin1))
        XCTAssertEqual(L.tostring(4), "îsø") // this should now succeed
#endif
    }

    func test_todata() {
        let data: [UInt8] = [12, 34, 0, 56]
        L.push(data)
        XCTAssertEqual(L.todata(1), data)
        XCTAssertEqual(L.tovalue(1), data)

        L.newtable()
        L.push(index: 1)
        L.rawset(-2, key: "abc")
        XCTAssertEqual(L.todata(2, key: "abc"), data)
    }

    func test_push_toindex() {
        L.push(333)
        L.push(111, toindex: 1)
        L.push(222, toindex: -2)
        XCTAssertEqual(L.toint(1), 111)
        XCTAssertEqual(L.toint(2), 222)
        XCTAssertEqual(L.toint(3), 333)
    }

    func test_ipairs() {
        let arr = [11, 22, 33, 44]
        L.push(arr) // Because Array<Int> conforms to Array<T: Pushable> which is itself Pushable
        var expected: lua_Integer = 0
        for i in L.ipairs(1) {
            expected = expected + 1
            XCTAssertEqual(i, expected)
            XCTAssertEqual(L.gettop(), 2)
            XCTAssertEqual(L.tointeger(2), expected * 11)
        }
        XCTAssertEqual(expected, 4)
        XCTAssertEqual(L.gettop(), 1)

        expected = 0
        for (i, intVal) in L.ipairs(1, type: Int8.self) {
            expected = expected + 1
            XCTAssertEqual(i, expected)
            XCTAssertEqual(L.gettop(), 1)
            XCTAssertEqual(intVal, Int8(expected * 11))
        }

        // Now check that a table with nils in is also handled correctly
        expected = 0
        L.pushnil()
        lua_rawseti(L, -2, 3) // arr[3] = nil
        for i in L.ipairs(1) {
            expected = expected + 1
            XCTAssertEqual(i, expected)
            XCTAssertEqual(L.gettop(), 2)
            XCTAssertEqual(L.tointeger(2), expected * 11)
        }
        XCTAssertEqual(expected, 2)
        XCTAssertEqual(L.gettop(), 1)
    }

    func test_LuaValue_ipairs_table() throws {
        let array = L.ref(any: [11, 22, 33, 44])
        var expected: lua_Integer = 0
        for (i, val) in try array.ipairs() {
            expected = expected + 1
            XCTAssertEqual(i, expected)
            XCTAssertEqual(L.gettop(), 0)
            XCTAssertEqual(val.tointeger(), expected * 11)
        }
        XCTAssertEqual(expected, 4)
        XCTAssertEqual(L.gettop(), 0)
    }

    func test_LuaValue_ipairs_mt() throws {
        // This errors on 5th index, thus appears to be an array of 4 items to ipairs
        try L.load(string: """
            local data = { 11, 22, 33, 44, 55, 66 }
            tbl = setmetatable({}, { __index = function(_, i)
                if i == 5 then
                    error("NOPE!")
                else
                    return data[i]
                end
            end})
            return tbl
            """)
        try L.pcall(nargs: 0, nret: 1)
        let array = L.popref()
        var expected: lua_Integer = 0
        for (i, val) in try array.ipairs() {
            expected = expected + 1
            XCTAssertEqual(i, expected)
            XCTAssertEqual(L.gettop(), 0)
            XCTAssertEqual(val.tointeger(), expected * 11)
        }
        XCTAssertEqual(expected, 4)
        XCTAssertEqual(L.gettop(), 0)
    }

    func test_LuaValue_ipairs_errors() throws {
        let bad_ipairs: (LuaValue) throws -> Void = { val in
            for _ in try val.ipairs() {
                XCTFail("Shouldn't get here!")
            }
        }
        XCTAssertThrowsError(try bad_ipairs(LuaValue()), "", { err in
            XCTAssertEqual(err as? LuaValueError, .nilValue)
        })
        XCTAssertThrowsError(try bad_ipairs(L.ref(any: 123)), "", { err in
            XCTAssertEqual(err as? LuaValueError, .notIndexable)
        })
    }

    func test_LuaValue_ipairs_type() throws {
        let arr: [AnyHashable] = [11, 22, 33, "four", 555]
        let val = L.ref(any: arr)
        var first: lua_Integer? = nil
        var last: lua_Integer? = nil
        for (i, elem) in try val.ipairs(start: 2, type: lua_Integer.self) {
            XCTAssertEqual(elem, i * 11)
            if first == nil {
                first = i
            }
            last = i
        }
        XCTAssertEqual(first, 2)
        XCTAssertEqual(last, 3)
    }

    func test_LuaValue_for_ipairs_errors() throws {
        let bad_ipairs: (LuaValue) throws -> Void = { val in
            try val.for_ipairs() { _, _ in
                XCTFail("Shouldn't get here!")
            }
        }
        XCTAssertThrowsError(try bad_ipairs(LuaValue()), "", { err in
            XCTAssertEqual(err as? LuaValueError, .nilValue)
        })
        XCTAssertThrowsError(try bad_ipairs(L.ref(any: 123)), "", { err in
            XCTAssertEqual(err as? LuaValueError, .notIndexable)
        })

        try L.load(string: "return setmetatable({}, { __index = function() error('DOOM!') end })")
        try L.pcall(nargs: 0, nret: 1)
        XCTAssertThrowsError(try bad_ipairs(L.popref()), "", { err in
            XCTAssertNotNil(err as? LuaCallError)
        })
    }

    func test_LuaValue_for_ipairs_type() throws {
        let arr = [11, 22, 33, 44, 55, 66]
        let arrValue = L.ref(any: arr)
        var expected_i: lua_Integer = 0
        try arrValue.for_ipairs(type: Int.self) { i, val in
            expected_i = expected_i + 1
            XCTAssertEqual(i, expected_i)
            XCTAssertEqual(val, arr[Int(i-1)])
            return i <= 4 ? .continueIteration : .breakIteration // Test we can bail early
        }
        XCTAssertEqual(expected_i, 5)

        // Test we don't explode when encountering the wrong type, and instead just exit the iteration
        let mixedArray: [Any] = ["abc", "def", 33]
        let mixedVal = L.ref(any: mixedArray)
        expected_i = 0
        try mixedVal.for_ipairs(type: String.self) { i, val -> Void in
            expected_i = expected_i + 1
            XCTAssertEqual(i, expected_i)
            XCTAssertEqual(val, mixedArray[Int(i-1)] as? String)
        }
        XCTAssertEqual(expected_i, 2)
    }

    func test_pairs() throws {
        let dict = [
            "aaa": 111,
            "bbb": 222,
            "ccc": 333,
        ]
        L.push(dict)
        var emptyingDict = dict
        for (k, v) in L.pairs(1) {
            XCTAssertTrue(k > 1)
            XCTAssertTrue(v > 1)
            let key = try XCTUnwrap(L.tostring(k))
            let val = try XCTUnwrap(L.toint(v))
            let foundVal = emptyingDict.removeValue(forKey: key)
            XCTAssertEqual(val, foundVal)
        }
        XCTAssertTrue(emptyingDict.isEmpty) // All entries should have been removed by the pairs loop

        L.push(dict)
        emptyingDict = dict
        for (key, val) in L.pairs(1, type: (String.self, Int.self)) {
            XCTAssertEqual(key.count, 3)
            XCTAssertTrue(val >= 111)
            let foundVal = emptyingDict.removeValue(forKey: key)
            XCTAssertEqual(val, foundVal)
        }
        XCTAssertTrue(emptyingDict.isEmpty) // All entries should have been removed by the pairs loop
    }

    func test_for_ipairs() throws {
        let arr = [11, 22, 33, 44, 55, 66]
        L.push(arr)
        var expected_i: lua_Integer = 0
        try L.for_ipairs(-1) { i in
            expected_i = expected_i + 1
            XCTAssertEqual(i, expected_i)
            XCTAssertEqual(L.toint(-1), arr[Int(i-1)])
            return i <= 4 ? .continueIteration : .breakIteration // Test we can bail early
        }
        XCTAssertEqual(expected_i, 5)

        // Check we're actually using non-raw accesses
        try L.load(string: """
            local data = { 11, 22, 33, 44 }
            tbl = setmetatable({}, { __index = data })
            return tbl
            """)
        try L.pcall(nargs: 0, nret: 1)
        expected_i = 1
        try L.for_ipairs(-1) { i -> Void in
            XCTAssertEqual(i, expected_i)
            expected_i = expected_i + 1
            XCTAssertEqual(L.toint(-1), arr[Int(i-1)])
        }

        // Check we can error from an indexing operation and not explode
        try L.load(string: """
            local data = { 11, 22, 33, 44 }
            tbl = setmetatable({}, {
                __index = function(_, idx)
                    if idx == 3 then
                        error("I'm an erroring __index")
                    else
                        return data[idx]
                    end
                end
            })
            return tbl
            """)
        try L.pcall(nargs: 0, nret: 1)
        var last_i: lua_Integer = 0
        let shouldError = {
            try self.L.for_ipairs(-1) { i in
                last_i = i
            }
        }
        XCTAssertThrowsError(try shouldError(), "", { err in
            XCTAssertNotNil(err as? LuaCallError)
        })
        XCTAssertEqual(last_i, 2)
    }

    func test_for_ipairs_type() throws {
        let arr = [11, 22, 33, 44, 55, 66]
        L.push(arr)
        var expected_i: lua_Integer = 0
        try L.for_ipairs(-1, type: Int.self) { i, val in
            expected_i = expected_i + 1
            XCTAssertEqual(i, expected_i)
            XCTAssertEqual(val, arr[Int(i-1)])
            return i <= 4 ? .continueIteration : .breakIteration // Test we can bail early
        }
        XCTAssertEqual(expected_i, 5)
        L.pop()

        // Test we don't explode when encountering the wrong type, and instead just exit the iteration
        let mixedArray: [Any] = ["abc", "def", 33]
        L.push(any: mixedArray)
        expected_i = 0
        try L.for_ipairs(-1, type: String.self) { (i: lua_Integer, val: String) -> Void in
            expected_i = expected_i + 1
            XCTAssertEqual(i, expected_i)
            XCTAssertEqual(val, mixedArray[Int(i-1)] as? String)
        }
        XCTAssertEqual(expected_i, 2)
    }

    func test_for_pairs_raw() throws {
        var dict = [
            "aaa": 111,
            "bbb": 222,
            "ccc": 333,
        ]
        L.push(dict)
        try L.for_pairs(1) { k, v -> Void in
            let key = try XCTUnwrap(L.tostring(k))
            let val = try XCTUnwrap(L.toint(v))
            let foundVal = dict.removeValue(forKey: key)
            XCTAssertEqual(val, foundVal)
        }
        XCTAssertTrue(dict.isEmpty) // All entries should have been removed by the pairs loop
    }

    // func test_for_pairs_perf_int_array() {
    //     L.newtable()
    //     for i in 1 ..< 10000000 {
    //         L.rawset(-1, key: i, value: i)
    //     }
    //     measure {
    //         try! L.for_pairs(-1, { _, _ in
    //             /* Do nothing */
    //             return true
    //         })
    //     }
    // }

    // func test_for_ipairs_perf_int_array() {
    //     L.newtable()
    //     for i in 1 ..< 10000000 {
    //         L.rawset(-1, key: i, value: i)
    //     }
    //     measure {
    //         try! L.for_ipairs(-1, { _ in
    //             /* Do nothing */
    //             return true
    //         })
    //     }
    // }

    func test_for_pairs_mt() throws {
        var dict = [
            "aaa": 111,
            "bbb": 222,
            "ccc": 333,
            "ddd": 444,
        ]

        // Check we're actually using non-raw accesses
        try L.load(string: """
            local dict = ...
            tbl = setmetatable({}, {
                __index = dict,
                __pairs = function(tbl)
                    return next, dict, nil
                end,
            })
            return tbl
            """)
        L.push(dict)
        try L.pcall(nargs: 1, nret: 1)

        try L.for_pairs(-1) { k, v -> Void in
            let key = try XCTUnwrap(L.tostring(k))
            let val = try XCTUnwrap(L.toint(v))
            let foundVal = dict.removeValue(forKey: key)
            XCTAssertEqual(val, foundVal)
        }
        XCTAssertTrue(dict.isEmpty) // All entries should have been removed by the pairs loop
    }

    func test_for_pairs_type() throws {
        let dict: [AnyHashable: AnyHashable] = [
            "aaa": 111,
            "bbb": 222,
            "ccc": "hello?",
            "ddd": 444,
        ]
        L.push(any: dict)
        var seenValues: [AnyHashable: AnyHashable] = [:]
        try L.for_pairs(-1, type: (String.self, Int.self)) { k, v in
            seenValues[k] = v
        }
        XCTAssertEqual(seenValues, ["aaa": 111, "bbb": 222, "ddd": 444])
    }

    func test_LuaValue_pairs_errors() throws {
        let bad_pairs: (LuaValue) throws -> Void = { val in
            for (_, _) in try val.pairs() {
                XCTFail("Shouldn't get here!")
            }
        }
        XCTAssertThrowsError(try bad_pairs(LuaValue()), "", { err in
            XCTAssertEqual(err as? LuaValueError, .nilValue)
        })
        XCTAssertThrowsError(try bad_pairs(L.ref(any: 123)), "", { err in
            XCTAssertEqual(err as? LuaValueError, .notIterable)
        })
    }

    func test_LuaValue_pairs_raw() throws {
        var dict = [
            "aaa": 111,
            "bbb": 222,
            "ccc": 333,
        ]
        let dictValue = L.ref(any: dict)
        for (k, v) in try dictValue.pairs() {
            let key = try XCTUnwrap(k.tostring())
            let val = try XCTUnwrap(v.toint())
            let foundVal = dict.removeValue(forKey: key)
            XCTAssertEqual(val, foundVal)
        }
        XCTAssertTrue(dict.isEmpty) // All entries should have been removed by the pairs loop
    }

    func test_LuaValue_pairs_mt() throws {
        var dict = [
            "aaa": 111,
            "bbb": 222,
            "ccc": 333,
            "ddd": 444,
        ]

        // Check we're actually using non-raw accesses
        try L.load(string: """
            local dict = ...
            tbl = setmetatable({}, {
                __index = dict,
                __pairs = function(tbl)
                    return next, dict, nil
                end,
            })
            return tbl
            """)
        L.push(dict)
        try L.pcall(nargs: 1, nret: 1)
        let dictValue = L.popref()
        let top = L.gettop()

        for (k, v) in try dictValue.pairs() {
            let key = try XCTUnwrap(k.tostring())
            let val = try XCTUnwrap(v.toint())
            let foundVal = dict.removeValue(forKey: key)
            XCTAssertEqual(val, foundVal)
        }
        XCTAssertEqual(L.gettop(), top)
        XCTAssertTrue(dict.isEmpty) // All entries should have been removed by the pairs loop
    }

    func test_LuaValue_for_pairs_mt() throws {
        var dict = [
            "aaa": 111,
            "bbb": 222,
            "ccc": 333,
            "ddd": 444,
        ]

        // Check we're actually using non-raw accesses
        try L.load(string: """
            local dict = ...
            return setmetatable({}, {
                __pairs = function()
                    return next, dict, nil
                end,
            })
            """)
        L.push(dict)
        try L.pcall(nargs: 1, nret: 1)
        let dictValue = L.popref()
        let top = L.gettop()

        try dictValue.for_pairs() { k, v -> Void in
            let key = try XCTUnwrap(k.tostring())
            let val = try XCTUnwrap(v.toint())
            let foundVal = dict.removeValue(forKey: key)
            XCTAssertEqual(val, foundVal)
        }
        XCTAssertEqual(L.gettop(), top)
        XCTAssertTrue(dict.isEmpty) // All entries should have been removed by the pairs loop
    }

    func test_LuaValue_pairs_mixeddict() throws {
        let dict: [String: Any] = [
            "aaa": 111,
            "bbb": 222,
            "ccc": "333",
            "ddd": 444,
            "eee": 555,
        ]
        let dictValue = L.ref(any: dict)
        var sawC = false
        // This isn't a guarantee we definitely skipped over mismatching types correctly, because we cannot predict
        // what order the iteration will proceed in as that is a Lua-internal impl detail
        for (k, v) in try dictValue.pairs(type: (String.self, String.self)) {
            XCTAssertEqual(k, "ccc")
            XCTAssertEqual(v, "333")
            XCTAssertEqual(sawC, false)
            sawC = true
        }
        XCTAssertTrue(sawC)
        sawC = false

        // And again with for_pairs
        try dictValue.for_pairs(type: (String.self, String.self)) { k, v -> Void in
            XCTAssertEqual(k, "ccc")
            XCTAssertEqual(v, "333")
            sawC = true
        }
        XCTAssertTrue(sawC)
    }

    func test_LuaValue_metatable() {
        XCTAssertNil(LuaValue().metatable)

        let t = LuaValue.newtable(L)
        XCTAssertNil(t.metatable)

        let mt = LuaValue.newtable(L)
        try! mt.set("foo", "bar")
        mt["__index"] = mt

        XCTAssertEqual(L.gettop(), 0)

        XCTAssertEqual(t["foo"].tostring(), nil)
        t.metatable = mt
        XCTAssertEqual(t["foo"].tostring(), "bar")
        XCTAssertEqual(t.metatable?.type, .table)
    }

    func test_LuaValue_equality() {
        XCTAssertEqual(LuaValue(), LuaValue())
        XCTAssertEqual(L.ref(any: nil), LuaValue())
        XCTAssertNotEqual(L.ref(any: 1), L.ref(any: 1))
        XCTAssertEqual(LuaValue().toboolean(), false)
        XCTAssertEqual(L.ref(any: 123.456).tonumber(), 123.456)
        XCTAssertEqual(L.ref(any: 123.0).tonumber(), 123)
        XCTAssertEqual(L.ref(any: 123).tonumber(), 123)
        XCTAssertEqual(L.ref(any: nil).tonumber(), nil)
    }

    func test_LuaValue_dump() throws {
        let val = try LuaValue.load(L, "return 42")
        let result: Int? = try val().tovalue()
        XCTAssertEqual(result, 42)
        XCTAssertEqual(L.gettop(), 0)

        let bytes = try XCTUnwrap(val.dump())
        try L.load(data: bytes, name: nil, mode: .binary)
        try L.pcall(nargs: 0, nret: 1)
        XCTAssertEqual(L.toint(-1), 42)
    }

    func test_pushuserdata() {
        struct Foo : Equatable {
            let intval: Int
            let strval: String
        }
        L.register(Metatable<Foo>())
        let val = Foo(intval: 123, strval: "abc")
        L.push(userdata: val)
        XCTAssertEqual(L.type(1), .userdata)

        // Check push(any:) handles it as a userdata too
        L.push(any: val)
        XCTAssertEqual(L.type(2), .userdata)
        L.pop()

        // Test toany
        let anyval = L.toany(1, guessType: false)
        XCTAssertEqual(anyval as? Foo, val)

        // Test the magic that tovalue does on top of toany
        let valFromLua: Foo? = L.tovalue(1)
        XCTAssertEqual(valFromLua, val)

        L.pop()
    }

    func test_pushlightuserdata() {
        let lud: UnsafeMutableRawPointer = malloc(4)!
        defer {
            free(lud)
        }
        L.push(lightuserdata: lud)
        XCTAssertEqual(L.type(-1), .lightuserdata)
        XCTAssertEqual(lua_touserdata(L, -1), lud)
        XCTAssertEqual(L.tolightuserdata(-1), lud)
        L.pop(1)

        L.push(any: lud)
        XCTAssertEqual(L.type(-1), .lightuserdata)
        XCTAssertEqual(lua_touserdata(L, -1), lud)
        XCTAssertEqual(L.tolightuserdata(-1), lud)
    }

    // Tests that objects deinit correctly when pushed with toany and GC'd by Lua
    func test_pushuserdata_instance() {
        var deinited = 0
        var val: DeinitChecker? = DeinitChecker { deinited += 1 }
        XCTAssertEqual(deinited, 0)

        L.register(Metatable<DeinitChecker>())
        L.push(userdata: val!)
        L.push(any: val!)
        var userdataFromPushUserdata: DeinitChecker? = L.touserdata(1)
        var userdataFromPushAny: DeinitChecker? = L.touserdata(2)
        XCTAssertIdentical(userdataFromPushUserdata, userdataFromPushAny)
        XCTAssertIdentical(userdataFromPushUserdata, val)
        L.pop() // We only need one ref Lua-side
        userdataFromPushAny = nil
        userdataFromPushUserdata = nil
        val = nil
        // Should not have destructed at this point, as reference still held by Lua
        L.collectgarbage()
        XCTAssertEqual(deinited, 0)
        L.pop()
        L.collectgarbage() // val should now destruct
        XCTAssertEqual(deinited, 1)
    }

    func test_pushuserdata_close() throws {
        try XCTSkipIf(!LUA_VERSION.is54orLater())

        var deinited = 0
        var val: DeinitChecker? = DeinitChecker { deinited += 1 }
        XCTAssertEqual(deinited, 0)

        L.register(Metatable<DeinitChecker>(close: .synthesize))
        XCTAssertEqual(L.gettop(), 0)

        // Avoid calling lua_toclose, to make this test still compile with Lua 5.3
        try L.load(string: """
            val = ...
            local arg <close> = val
            """)
        L.push(userdata: val!)
        val = nil
        XCTAssertEqual(deinited, 0)
        do {
            let valUserdata: DeinitChecker? = L.touserdata(-1)
            XCTAssertNotNil(valUserdata)
        }
        try L.pcall(nargs: 1, nret: 0)
        XCTAssertEqual(deinited, 1)
        XCTAssertEqual(L.getglobal("val"), .userdata)
        do {
            // After being closed, touserdata should no longer return it
            let valUserdata: DeinitChecker? = L.touserdata(-1)
            XCTAssertNil(valUserdata)
        }
        L.pop()

        L.setglobal(name: "val", value: .nilValue)
        L.collectgarbage()
        XCTAssertEqual(deinited, 1)
    }

    func test_pushuserdata_Closeable_close() throws {
        try XCTSkipIf(!LUA_VERSION.is54orLater())

        var deinited = 0
        var closed = 0
        var val: DeinitChecker? = ClosableDeinitChecker(deinitFn: { deinited += 1 }, closeFn: { closed += 1 })
        XCTAssertEqual(deinited, 0)
        XCTAssertEqual(closed, 0)

        L.register(Metatable<ClosableDeinitChecker>(close: .synthesize))
        XCTAssertEqual(L.gettop(), 0)

        // Avoid calling lua_toclose, to make this test still compile with Lua 5.3
        try L.load(string: """
            val = ...
            local arg <close> = val
            """)
        L.push(userdata: val!)
        val = nil
        XCTAssertEqual(deinited, 0)
        XCTAssertEqual(closed, 0)
        do {
            let valUserdata: DeinitChecker? = L.touserdata(-1)
            XCTAssertNotNil(valUserdata)
        }
        try L.pcall(nargs: 1, nret: 0)
        XCTAssertEqual(deinited, 0)
        XCTAssertEqual(closed, 1)
        XCTAssertEqual(L.getglobal("val"), .userdata)
        do {
            // Since the type implements Closable, touserdata _should_ still return it
            let valUserdata: DeinitChecker? = L.touserdata(-1)
            XCTAssertNotNil(valUserdata)
        }
        L.pop()

        L.setglobal(name: "val", value: .nilValue)
        L.collectgarbage()
        XCTAssertEqual(deinited, 1)
        XCTAssertEqual(closed, 1)
    }

    func test_legacy_registerMetatable() throws {
        class SomeClass {
            var member: String? = nil
        }
        var barCalled = false
        XCTAssertFalse(L.isMetatableRegistered(for: SomeClass.self))
        L.internal_registerMetatable(for: SomeClass.self, functions: [
            "__call": .function { (L: LuaState!) -> CInt in
                guard let obj: SomeClass = L.touserdata(1) else {
                    fatalError("Shouldn't happen")
                }
                obj.member = L.tostring(2)
                return 0
            },
            "bar": .closure { L in
                barCalled = true
                return 0
            }
        ])
        XCTAssertTrue(L.isMetatableRegistered(for: SomeClass.self))
        let val = SomeClass()
        L.push(userdata: val)
        try L.pcall("A string arg")
        XCTAssertEqual(val.member, "A string arg")

        try L.load(string: "foo = ...; foo.bar()")
        L.push(any: SomeClass())
        XCTAssertFalse(barCalled)
        try L.pcall(nargs: 1, nret: 0)
        XCTAssertTrue(barCalled)
    }

    func test_registerMetatable() throws {
        class SomeClass {
            var member: String? = nil
            let data: [UInt8] = [1, 2, 3]

            func voidfn() {}
            func strstr(str: String) -> String {
                return str + "!"
            }
            func optstrstr(str: String?) -> String {
                return str ?? "!"
            }
        }

        XCTAssertFalse(L.isMetatableRegistered(for: SomeClass.self))
        L.register(Metatable<SomeClass>(
            fields: [
                "member": .property(get: { $0.member }, set: { $0.member = $1 }),
                "data": .property { $0.data },
                "strstr": .memberfn { $0.strstr(str: $1) },
                "optstrstr": .memberfn { $0.optstrstr(str: $1) },
                "voidfn": .memberfn { $0.voidfn() },
            ],
            call: .memberfn { (obj: SomeClass, str: String) in
                obj.member = str
            }
        ))
        XCTAssertTrue(L.isMetatableRegistered(for: SomeClass.self))

        let val = SomeClass()
        L.push(userdata: val)

        L.push(index: 1)
        try L.pcall("A string arg")
        XCTAssertEqual(val.member, "A string arg")

        try L.get(1, key: "member")
        XCTAssertEqual(L.tostring(-1), "A string arg")
        L.pop()

        try L.set(1, key: "member", value: "anewval")
        XCTAssertEqual(val.member, "anewval")

        try L.set(1, key: "member", value: .nilValue)
        XCTAssertNil(val.member)
        try L.get(1, key: "member")
        XCTAssertNil(L.tovalue(-1, type: String.self))
        L.pop()

        try L.get(1, key: "data")
        XCTAssertEqual(L.todata(-1), [1, 2, 3])
        L.pop()

        try L.get(1, key: "strstr")
        L.push(index: 1)
        L.push("woop")
        try L.pcall(nargs: 2, nret: 1)
        XCTAssertEqual(L.tostring(-1), "woop!")
        L.pop()

        try L.get(1, key: "optstrstr")
        L.push(index: 1)
        L.pushnil()
        try L.pcall(nargs: 2, nret: 1)
        XCTAssertEqual(L.tostring(-1), "!")
        L.pop()
    }

    func test_registerMetatable_name() throws {
        class SomeClass {}
        class SomeNamedClass {}

        L.register(Metatable<SomeClass>())
        L.register(Metatable<SomeNamedClass>(fields: [
            "__name": .constant("SomeNamedClass")
        ]))

        L.push(userdata: SomeClass())
        let s1 = try XCTUnwrap(L.tostring(-1, convert: true))
        XCTAssertTrue(s1.hasPrefix("LuaSwift_Type_SomeClass: "))

        L.push(userdata: SomeNamedClass())
        let s2 = try XCTUnwrap(L.tostring(-1, convert: true))
        XCTAssertTrue(s2.hasPrefix("SomeNamedClass: "))
    }

    func test_PushableWithMetatable_struct() throws {
        struct Foo: PushableWithMetatable {
            func foo() -> String { return "Foo.foo" }

            static let metatable = Metatable<Foo>(fields: [
                "foo": .memberfn { $0.foo() }
            ])
        }

        let val = L.ref(any: Foo())
        XCTAssertEqual(try val.pcall(member: "foo").tostring(), "Foo.foo")
    }

    func test_PushableWithMetatable_class() throws {
        class Derived: test_PushableWithMetatable_Base {
            override func foo() -> String { return "Derived.foo" }
        }

        let derived = L.ref(any: Derived())
        XCTAssertEqual(try derived.pcall(member: "foo").tostring(), "Derived.foo")
    }

    func test_PushableWithMetatable_derivedCustomMt() throws {
        class Base: PushableWithMetatable {
            func foo() -> String { return "Base.foo" }
            class var metatable: Metatable<Base> {
                return Metatable(fields: [
                    "foo": .memberfn { $0.foo() }
                ])
            }
        }
        class Derived: Base {
            override func foo() -> String { return "Derived.foo" }
            func bar() -> String { return "Derived.bar" }
            class override var metatable: Metatable<Base> {
                return Metatable<Derived>(fields: [
                    "foo": .memberfn { $0.foo() },
                    "bar": .memberfn { $0.bar() }
                ]).downcast()
            }
        }

        let derived = L.ref(any: Derived())
        XCTAssertEqual(try derived.pcall(member: "foo").tostring(), "Derived.foo")
        XCTAssertEqual(try derived.pcall(member: "bar").tostring(), "Derived.bar")
    }

    func test_PushableWithMetatable_protocol() throws {
        class Base: TestMetatabledProtocol {
            func foo() -> String { return "Base.foo" }
        }

        let base = L.ref(any: Base())
        XCTAssertEqual(try base.pcall(member: "foo").tostring(), "Base.foo")

        class Derived: Base {
            override func foo() -> String { return "Derived.foo" }
        }

        let derived = L.ref(any: Derived())
        XCTAssertEqual(try derived.pcall(member: "foo").tostring(), "Derived.foo")
    }

    func test_PushableWithMetatable_autoRegister() throws {

        struct Foo: PushableWithMetatable {
            func foo() -> String { return "Foo.foo" }

            // Intentionally conflict with the internal helper fn name, to make sure it doesn't get picked up
            public func checkRegistered(state: LuaState) {
                fatalError("Shouldn't be called")
            }

            static let metatable = Metatable<Foo>(fields: [
                "foo": .memberfn { $0.foo() }
            ])
        }

        L.push(userdata: Foo())
        let val = L.popref()
        let result = try val.pcall(member: "foo")
        XCTAssertEqual(result.tostring(), "Foo.foo")
    }

    func test_legacy_registerDefaultMetatable() throws {
        struct Foo {}
        var called = false
        L.internal_registerDefaultMetatable(functions: [
            "woop": .closure { L in
                L.push(321)
                return 1
            },
            "__call": .closure { L in
                called = true
                return 0
            }
        ])
        try L.load(string: "obj = ...; return obj.woop()")
        // Check that Foo gets the default metatable with a woop() fn
        L.push(userdata: Foo())
        try L.pcall(nargs: 1, nret: 1)
        XCTAssertEqual(L.tovalue(1), 321)

        L.push(userdata: Foo())
        XCTAssertEqual(called, false)
        try L.pcall(nargs: 0, nret: 0)
        XCTAssertEqual(called, true)
    }

    func test_registerDefaultMetatable() throws {
        struct Foo {}
        L.register(DefaultMetatable(
            call: .closure { L in
                L.push(321)
                return 1
            }
        ))
        try L.load(string: "obj = ...; return obj()")
        // Check that Foo gets the default metatable and is callable
        L.push(userdata: Foo())
        try L.pcall(nargs: 1, nret: 1)
        XCTAssertEqual(L.tovalue(1), 321)
    }

    func test_equatableMetamethod() throws {
        struct Foo: Equatable {
            let member: Int
        }
        struct Bar: Equatable {
            let member: Int
        }
        L.register(Metatable<Foo>(eq: .synthesize))
        L.register(Metatable<Bar>())
        // Note, Bar not getting an __eq

        L.push(userdata: Foo(member: 111)) // 1
        L.push(userdata: Foo(member: 111)) // 2: a different Foo but same value
        L.push(index: 1) // 3: same object as 1
        L.push(userdata: Foo(member: 222)) // 4: a different Foo with different value
        L.push(userdata: Bar(member: 333)) // 5: a Bar
        L.push(userdata: Bar(member: 333)) // 6: a different Bar but with same value
        L.push(index: 5) // 7: same object as 5

        XCTAssertTrue(try L.compare(1, 1, .eq))
        XCTAssertTrue(try L.compare(1, 2, .eq))
        XCTAssertTrue(try L.compare(2, 1, .eq))
        XCTAssertTrue(try L.compare(3, 1, .eq))
        XCTAssertFalse(try L.compare(1, 4, .eq))

        XCTAssertTrue(try L.compare(5, 5, .eq)) // same object
        XCTAssertFalse(try L.compare(5, 6, .eq)) // Because Bar doesn't have an __eq
        XCTAssertTrue(try L.compare(5, 7, .eq)) // same object

        XCTAssertFalse(try L.compare(1, 5, .eq)) // A Foo and a Bar can never compare equal
    }

    func test_comparableMetamethod() throws {
        struct Foo: Comparable {
            let member: Int
            static func < (lhs: Foo, rhs: Foo) -> Bool {
                return lhs.member < rhs.member
            }
        }
        L.register(Metatable<Foo>(eq: .synthesize, lt: .synthesize, le: .synthesize))

        L.push(userdata: Foo(member: 111)) // 1
        L.push(userdata: Foo(member: 222)) // 2

        XCTAssertTrue(try L.compare(1, 1, .le))
        XCTAssertTrue(try L.compare(1, 1, .eq))
        XCTAssertFalse(try L.compare(1, 1, .lt))
        XCTAssertTrue(try L.compare(1, 2, .lt))
        XCTAssertFalse(try L.compare(2, 1, .le))
    }

    func test_pairsMetamethod() throws {
        struct Foo {
            let a: String
            let b: Int
        }
        L.register(Metatable<Foo>(pairs: .closure { L in
            // Fn starts with stack 1=obj
            L.push({ L in
                let obj: Foo = try L.checkArgument(1)
                let idx: String? = L.tostring(2)
                switch idx {
                case .none:
                    L.push("a")
                    L.push(obj.a)
                case "a":
                    L.push("b")
                    L.push(obj.b)
                default:
                    L.pushnil()
                    L.pushnil()
                }
                return 2
            }, toindex: 1)
            L.pushnil()
            // returning fn, obj, nil
            return 3
        }))


        try L.load(string: """
            local obj = ...
            local result = {}
            for k, v in pairs(obj) do
                result[k] = v
            end
            return result
            """)
        let foo = Foo(a: "abc", b: 123)
        L.push(userdata: foo)
        try L.pcall(nargs: 1, nret: 1)
        let expected: Dictionary<String, AnyHashable> = ["a": "abc", "b": 123]
        XCTAssertEqual(L.tovalue(1), expected)
    }

    func test_tostringMetamethod() throws {
        struct Foo {
            func str() -> String {
                return "woop"
            }
        }
        L.register(Metatable<Foo>(tostring: .memberfn { $0.str() }))
        L.push(userdata: Foo())
        let result = L.tostring(1, convert: true)
        XCTAssertEqual(result, "woop")
    }

    func test_synthesize_tostring() throws {
        struct Foo {}
        L.register(Metatable<Foo>(tostring: .synthesize))
        L.push(userdata: Foo())
        let str = try XCTUnwrap(L.tostring(1, convert: true))
        XCTAssertEqual(str, "Foo()")

        struct NoTostringStruct {}
        L.register(Metatable<NoTostringStruct>())
        L.push(userdata: NoTostringStruct())
        let nonTostringStr = try XCTUnwrap(L.tostring(-1, convert: true))
        if LUA_VERSION.releaseNum >= 50303 {
            // The use of __name in tostring wasn't added until 5.3.3
            XCTAssertTrue(nonTostringStr.hasPrefix("LuaSwift_Type_NoTostringStruct: ")) // The default behaviour of tostring for a named userdata
        }

        struct CustomStruct: CustomStringConvertible {
            var description: String {
                return "woop"
            }
        }
        L.register(Metatable<CustomStruct>(tostring: .synthesize))
        L.push(userdata: CustomStruct())
        let customStr = try XCTUnwrap(L.tostring(-1, convert: true))
        XCTAssertEqual(customStr, "woop")
    }

    func testClasses() throws {
        // "outer Foo"
        class Foo {
            var str: String?
        }
        let f = Foo()
        XCTAssertFalse(L.isMetatableRegistered(for: Foo.self))
        L.register(Metatable<Foo>(call: .closure { L in
            let f: Foo = try XCTUnwrap(L.touserdata(1))
            // Above would have failed if we get called with an innerfoo
            f.str = L.tostring(2)
            return 0
        }))
        XCTAssertTrue(L.isMetatableRegistered(for: Foo.self))
        L.push(userdata: f)

        do {
            // A different Foo ("inner Foo")
            class Foo {
                var str: String?
            }
            XCTAssertFalse(L.isMetatableRegistered(for: Foo.self))
            L.register(Metatable<Foo>(call: .closure { L in
                let f: Foo = try XCTUnwrap(L.touserdata(1))
                // Above would have failed if we get called with an outerfoo
                f.str = L.tostring(2)
                return 0
            }))
            XCTAssertTrue(L.isMetatableRegistered(for: Foo.self))
            let g = Foo()
            L.push(userdata: g)

            try L.pcall("innerfoo") // pops g
            try L.pcall("outerfoo") // pops f

            XCTAssertEqual(g.str, "innerfoo")
            XCTAssertEqual(f.str, "outerfoo")
        }
    }

    func test_toany() throws {
        // Things not covered by any of the other pushany tests

        XCTAssertNil(L.toany(1))

        L.pushnil()
        XCTAssertNil(L.toany(1))
        L.pop()

        try L.dostring("function foo() end")
        L.getglobal("foo")
        XCTAssertNotNil(L.toany(1) as? LuaValue)
        L.pop()

        lua_newthread(L)
        XCTAssertNotNil(L.toany(1) as? LuaState)
        L.pop()

        let m = malloc(4)
        defer {
            free(m)
        }
        L.push(lightuserdata: m)
        XCTAssertEqual(L.toany(1) as? UnsafeMutableRawPointer, m)
        L.pop()

        L.push(lightuserdata: nil)
        let nullptr = try XCTUnwrap(L.toany(1))
        // It's impossible to type check a nil optional wrapped in an Any to any exact type, because Optional<Foo>.none
        // is always castable to Optional<Bar> regardless of the types. So the best we can check for here is that
        // toany returned Optional<something>.nil
        switch nullptr {
        case let opt as Optional<UnsafeMutableRawPointer>:
            XCTAssertNil(opt)
        default:
            XCTFail()
        }

        let optraw = nullptr as? Optional<UnsafeRawPointer>
        XCTAssertEqual(optraw, Optional<UnsafeRawPointer>.none)
    }

    func test_pushany() {
        L.push(any: 1234)
        XCTAssertEqual(L.toany(1) as? lua_Integer, 1234)
        L.pop()

        L.push(any: "string")
        XCTAssertNil(L.toany(1, guessType: false) as? String)
        XCTAssertNotNil(L.toany(1, guessType: true) as? String)
        XCTAssertNotNil(L.toany(1, guessType: false) as? LuaStringRef)
        L.pop()

        // This is directly pushable (because Int is)
        let intArray = [11, 22, 33]
        L.push(any: intArray)
        XCTAssertEqual(L.type(1), .table)
        L.pop()

        struct Foo : Equatable {
            let val: String
        }
        L.register(Metatable<Foo>())
        let fooArray = [Foo(val: "a"), Foo(val: "b")]
        L.push(any: fooArray)
        XCTAssertEqual(L.type(1), .table)
        let guessAnyArray = L.toany(1, guessType: true) as? Array<Any>
        XCTAssertNotNil(guessAnyArray)
        XCTAssertEqual((guessAnyArray?[0] as? Foo)?.val, "a")
        let typedArray = guessAnyArray as? Array<Foo>
        XCTAssertNotNil(typedArray)

        let arr: [Foo]? = L.tovalue(1)
        XCTAssertEqual(arr, fooArray)
        L.pop()

        let uint8: UInt8 = 123
        L.push(any: uint8)
        XCTAssertEqual(L.toint(-1), 123)
        L.pop()
    }

    func test_pushany_table() { // This doubles as test_tovalue_table()
        let stringArray = ["abc", "def"]
        L.push(any: stringArray)
        let stringArrayResult: [String]? = L.tovalue(1)
        XCTAssertEqual(stringArrayResult, stringArray)
        L.pop()

        // Make sure non-lua_Integer arrays work...
        let intArray: [Int] = [11, 22, 33]
        L.push(any: intArray)
        let intArrayResult: [Int]? = L.tovalue(1)
        XCTAssertEqual(intArrayResult, intArray)
        L.pop()

        let smolIntArray: [UInt8] = [11, 22, 33]
        L.push(any: smolIntArray)
        let smolIntArrayResult: [UInt8]? = L.tovalue(1)
        XCTAssertEqual(smolIntArrayResult, smolIntArray)
        L.pop()

        let stringArrayArray = [["abc", "def"], ["123"]]
        L.push(any: stringArrayArray)
        let stringArrayArrayResult: [[String]]? = L.tovalue(1)
        XCTAssertEqual(stringArrayArrayResult, stringArrayArray)
        L.pop()

        let intBoolDict = [ 1: true, 2: false, 3: true ]
        L.push(any: intBoolDict)
        let intBoolDictResult: [Int: Bool]? = L.tovalue(1)
        XCTAssertEqual(intBoolDictResult, intBoolDict)
        L.pop()

        let intIntDict: [Int16: Int16] = [ 1: 11, 2: 22, 3: 33 ]
        L.push(any: intIntDict)
        let intIntDictResult: [Int16: Int16]? = L.tovalue(1)
        XCTAssertEqual(intIntDictResult, intIntDict)
        L.pop()

        let stringDict = ["abc": "ABC", "def": "DEF"]
        L.push(any: stringDict)
        let stringDictResult: [String: String]? = L.tovalue(1)
        XCTAssertEqual(stringDictResult, stringDict)
        L.pop()

        let arrayDictDict = [["abc": [1: "1", 2: "2"], "def": [5: "5", 6: "6"]]]
        L.push(any: arrayDictDict)
        let arrayDictDictResult: [[String : [Int : String]]]? = L.tovalue(1)
        XCTAssertEqual(arrayDictDictResult, arrayDictDict)
        L.pop()

        let intDict = [11: [], 22: ["22a", "22b"], 33: ["3333"]]
        L.push(any: intDict)
        let intDictResult: [Int: [String]]? = L.tovalue(1)
        XCTAssertEqual(intDictResult, intDict)
        L.pop()

        let uint8Array: [ [UInt8] ] = [ [0x61, 0x62, 0x63], [0x64, 0x65, 0x66] ] // Same as stringArray above
        L.push(any: uint8Array)
        let uint8ArrayResult: [ [UInt8] ]? = L.tovalue(1)
        XCTAssertEqual(uint8ArrayResult, uint8Array)
        let uint8ArrayAsStringResult: [String]? = L.tovalue(1)
        XCTAssertEqual(uint8ArrayAsStringResult, stringArray)
#if !LUASWIFT_NO_FOUNDATION
        let dataArray = uint8Array.map({ Data($0) })
        let uint8ArrayAsDataResult: [Data]? = L.tovalue(1)
        XCTAssertEqual(uint8ArrayAsDataResult, dataArray)
#endif
        L.pop()

        L.push(any: stringArray)
        let stringAsUint8ArrayResult: [ [UInt8] ]? = L.tovalue(1)
        XCTAssertEqual(stringAsUint8ArrayResult, uint8Array)
#if !LUASWIFT_NO_FOUNDATION
        let stringAsDataArrayResult: [Data]? = L.tovalue(1)
        XCTAssertEqual(stringAsDataArrayResult, dataArray)
#endif
        L.pop()

#if !LUASWIFT_NO_FOUNDATION
        L.push(any: stringDict)
        let stringDictAsDataDict: [Data: Data]? = L.tovalue(1)
        var dataDict: [Data: Data] = [:]
        for (k, v) in stringDict {
            dataDict[k.data(using: .utf8)!] = v.data(using: .utf8)!
        }
        XCTAssertEqual(stringDictAsDataDict, dataDict)
#endif
    }

    func test_push_tuple() throws {
        let empty: Void = ()
        XCTAssertEqual(L.push(tuple: empty), 0)
        XCTAssertEqual(L.gettop(), 0)

        // Sanity check that a function returning void is also acceptable
        let voidfn: () -> Void = {}
        XCTAssertEqual(L.push(tuple: voidfn()), 0)
        XCTAssertEqual(L.gettop(), 0)

        let singleNonTuple = "hello"
        XCTAssertEqual(L.push(tuple: singleNonTuple), 1)
        XCTAssertEqual(L.gettop(), 1)
        XCTAssertEqual(L.tovalue(1), "hello")
        L.settop(0)

        let pair = (123, "abc")
        XCTAssertEqual(L.push(tuple: pair), 2)
        XCTAssertEqual(L.gettop(), 2)
        XCTAssertEqual(L.tovalue(1), 123)
        XCTAssertEqual(L.tovalue(2), "abc")
        L.settop(0)

        let namedPair = (foo: "bar", baz: false)
        XCTAssertEqual(L.push(tuple: namedPair), 2)
        XCTAssertEqual(L.gettop(), 2)
        XCTAssertEqual(L.tovalue(1), "bar")
        XCTAssertEqual(L.tovalue(2), false)
        L.settop(0)

        let triple: (Int, Bool?, String) = (123, nil, "abc")
        XCTAssertEqual(L.push(tuple: triple), 3)
        XCTAssertEqual(L.gettop(), 3)
        XCTAssertEqual(L.tovalue(1), 123)
        XCTAssertEqual(L.tovalue(2, type: Bool.self), nil)
        XCTAssertEqual(L.tovalue(3), "abc")
        L.settop(0)

    }

    func test_push_helpers() throws {
        L.setglobal(name: "foo", value: .function { L in
            L!.push(42)
            return 1
        })
        L.getglobal("foo")
        XCTAssertEqual(try L.pcall(), 42)

        L.setglobal(name: "foo", value: .closure { L in
            L.push(123)
            return 1
        })
        L.getglobal("foo")
        XCTAssertEqual(try L.pcall(), 123)

        L.setglobal(name: "hello", value: .data([0x77, 0x6F, 0x72, 0x6C, 0x64]))
        XCTAssertEqual(L.globals["hello"].tovalue(), "world")

        L.setglobal(name: "hello", value: .nilValue)
        XCTAssertEqual(L.globals["hello"].type, .nil)

        class Foo {
            func bar() -> Int {
                return 42
            }
        }
        L.register(Metatable<Foo>(fields: [
            "bar": .memberfn { $0.bar() }
        ]))
        L.setglobal(name: "foo", value: .userdata(Foo()))
        XCTAssertEqual(L.globals["foo"].type, .userdata)
        XCTAssertEqual(try L.globals["foo"].pcall(member: "bar").toint(), 42)
    }

    func test_push_closure() throws {
        var called = false
        L.push(closure: {
            called = true
        })
        try L.pcall()
        XCTAssertTrue(called)

        // Check the trailing closure syntax works too
        called = false
        L.push() { () -> Int? in
            called = true
            return 123
        }
        let iresult: Int? = try L.pcall()
        XCTAssertTrue(called)
        XCTAssertEqual(iresult, 123)

        called = false
        L.push() { (L: LuaState) -> CInt in
            called = true
            L.push("result")
            return 1
        }
        var sresult: String? = try L.pcall()
        XCTAssertTrue(called)
        XCTAssertEqual(sresult, "result")

        L.push(closure: {
            return "Void->String closure"
        })
        XCTAssertEqual(try L.pcall(), "Void->String closure")

        L.push() {
            return "Void->String trailing closure"
        }
        XCTAssertEqual(try L.pcall(), "Void->String trailing closure")

        let c = { (val: String?) -> String in
            let v = val ?? "no"
            return "\(v) result"
        }
        L.push(closure: c)
        let result: String? = try L.pcall("call")
        XCTAssertEqual(result, "call result")

        L.push(closure: c)
        XCTAssertThrowsError(try L.pcall(1234, traceback: false), "", { err in
            XCTAssertEqual((err as? LuaCallError)?.errorString,
                           "bad argument #1 to '?' (Expected type convertible to Optional<String>, got number)")
        })

        L.push(closure: c)
        sresult = try L.pcall(nil)
        XCTAssertEqual(sresult, "no result")

        // Test multiple return support

        XCTAssertEqual(L.gettop(), 0)
        L.push(closure: {})
        try L.pcall(nargs: 0, nret: MultiRet)
        XCTAssertEqual(L.gettop(), 0)

        // One arg case is tested elsewhere, but for completeness
        L.push(closure: { return 123 })
        try L.pcall(nargs: 0, nret: MultiRet)
        XCTAssertEqual(L.gettop(), 1)
        L.settop(0)

        L.push(closure: { return (123, 456) })
        try L.pcall(nargs: 0, nret: MultiRet)
        XCTAssertEqual(L.gettop(), 2)
        XCTAssertEqual(L.tovalue(1), 123)
        XCTAssertEqual(L.tovalue(2), 456)
        L.settop(0)

        L.push(closure: { return (123, "abc", Optional<String>.none) })
        try L.pcall(nargs: 0, nret: MultiRet)
        XCTAssertEqual(L.gettop(), 3)
        XCTAssertEqual(L.tovalue(1), 123)
        XCTAssertEqual(L.tovalue(2), "abc")
        XCTAssertNil(L.tovalue(3))
        L.settop(0)
    }

    func test_push_any_closure() throws {
        var called = false
        let voidVoidClosure = {
            called = true
        }
        L.push(any: voidVoidClosure)
        try L.pcall()
        XCTAssertTrue(called)

        called = false
        let voidAnyClosure = { () throws -> Any? in
            called = true
            return nil
        }

        L.push(any: voidAnyClosure)
        try L.pcall()
        XCTAssertTrue(called)
    }

    func test_extension_4arg_closure() throws {
        // Test that more argument overloads of push(closure:) can be implemented if required by code not in the Lua
        // package.
        func push<Arg1, Arg2, Arg3, Arg4>(closure: @escaping (Arg1, Arg2, Arg3, Arg4) throws -> Any?) {
            L.push(LuaClosureWrapper({ L in
                let arg1: Arg1 = try L.checkArgument(1)
                let arg2: Arg2 = try L.checkArgument(2)
                let arg3: Arg3 = try L.checkArgument(3)
                let arg4: Arg4 = try L.checkArgument(4)
                L.push(any: try closure(arg1, arg2, arg3, arg4))
                return 1
            }))
        }
        var gotArg4: String? = nil
        push(closure: { (arg1: Bool, arg2: Int?, arg3: String?, arg4: String) in
            gotArg4 = arg4
        })
        try L.pcall(true, 0, nil, "woop")
        XCTAssertEqual(gotArg4, "woop")
    }

    func testNonHashableTableKeys() {
        struct NonHashable {
            let nope = true
        }
        L.register(Metatable<NonHashable>())
        lua_newtable(L)
        L.push(userdata: NonHashable())
        L.push(true)
        lua_settable(L, -3)
        let tbl = L.toany(1, guessType: true) as? [LuaValue: Bool]
        XCTAssertNotNil(tbl)
    }

    func testAnyHashable() {
        // Just to make sure casting to AnyHashable behaves as expected
        let x: Any = 1
        XCTAssertNotNil(x as? AnyHashable)
        struct NonHashable {}
        let y: Any = NonHashable()
        XCTAssertNil(y as? AnyHashable)
    }

    func testForeignUserdata() {
        // Tests that a userdata not set via pushuserdata (and thus, doesn't necessarily contain an `Any`) does not
        // crash or return anything if you attempt to access it via touserdata().
        let userdataPtr = lua_newuserdata(L, MemoryLayout<Any>.size)
        let bad: Any? = L.touserdata(-1)
        XCTAssertNil(bad)

        // But it should be returnable as a UnsafeRawPointer or UnsafeMutableRawPointer
        let ptr: UnsafeRawPointer? = L.tovalue(-1)
        XCTAssertEqual(ptr, UnsafeRawPointer(userdataPtr))

        let mutptr: UnsafeMutableRawPointer? = L.tovalue(-1)
        XCTAssertEqual(mutptr, userdataPtr)

        // Now give it a metatable, because touserdata bails early if it doesn't have one
        L.newtable()
        lua_setmetatable(L, -2)
        let stillbad: Any? = L.touserdata(-1)
        XCTAssertNil(stillbad)
    }

    func test_tovalue_userdata_array() throws {
        let lud: UnsafeMutableRawPointer = malloc(4)
        defer {
            free(lud)
        }
        L.push(lightuserdata: lud) // 1
        let ud = lua_newuserdata(L, 8)! // 2
        L.push(lightuserdata: nil) // 3

        L.newtable()
        L.push(index: 1)
        L.rawset(-2, key: 1)
        L.push(index: 2)
        L.rawset(-2, key: 2)
        L.push(index: 3)
        L.rawset(-2, key: 3)

        // top is now an array [lightuserdata, userdata, nulllightuserdata]

        // Have to make this optional type because of the null lightuserdata
        let mutArr: Array<UnsafeMutableRawPointer?> = try XCTUnwrap(L.tovalue(-1))
        let expectedMutArr: [UnsafeMutableRawPointer?] = [lud, ud, nil]
        XCTAssertEqual(mutArr, expectedMutArr)

        let nopeMutArray: Array<UnsafeMutableRawPointer>? = L.tovalue(-1)
        XCTAssertNil(nopeMutArray) // Fails because of the nullptr lightuserdata

        let arr: Array<UnsafeRawPointer?> = try XCTUnwrap(L.tovalue(-1))
        let expectedArr: [UnsafeRawPointer?] = [UnsafeRawPointer(lud), UnsafeRawPointer(ud), nil]
        XCTAssertEqual(arr, expectedArr)

        // remove the null lightuserdata, retest that non-optionals now succeed
        L.rawset(-1, key: 3, value: .nilValue)
        let mutNonOptArr: Array<UnsafeMutableRawPointer> = try XCTUnwrap(L.tovalue(-1))
        let expectedNonOptMutArr: [UnsafeMutableRawPointer] = [lud, ud]
        XCTAssertEqual(mutNonOptArr, expectedNonOptMutArr)
    }

    func test_tovalue_userdata_dict() throws {
        let ud: UnsafeMutableRawPointer = lua_newuserdata(L, 8)
        let udVal: LuaValue = L.popref()
        let lud: UnsafeMutableRawPointer = malloc(4)
        defer {
            free(lud)
        }
        let ludVal = L.ref(any: lud)

        L.push(["ud": udVal, "lud": ludVal])
        let string_mutptr_dict: [String: UnsafeMutableRawPointer] = ["ud": ud, "lud": lud]
        XCTAssertEqual(L.tovalue(-1), string_mutptr_dict)

        let string_ptr_dict: [String: UnsafeRawPointer] = ["ud": UnsafeRawPointer(ud), "lud": UnsafeRawPointer(lud)]
        XCTAssertEqual(L.tovalue(-1), string_ptr_dict)

        L.pop()

        L.push([udVal: ludVal])
        XCTAssertEqual(L.tovalue(-1), [ud: UnsafeRawPointer(lud)])
        let anyDict: [AnyHashable: AnyHashable] = [ud: lud]
        XCTAssertEqual(L.tovalue(-1), anyDict)
    }

    func test_tolightuserdata() throws {
        let lud = malloc(4)!
        defer {
            free(lud)
        }

        L.push(lightuserdata: lud)
        if let gotlud: UnsafeMutableRawPointer? = L.tolightuserdata(-1) {
            XCTAssertEqual(gotlud, lud)
        } else {
            XCTFail()
        }
        XCTAssertTrue(L.tolightuserdata(-1) == lud)

        let tovalueLud: UnsafeMutableRawPointer? = L.tovalue(-1)
        XCTAssertEqual(tovalueLud, lud)

        L.pop()

        L.push(lightuserdata: nil)
        if let gotlud: UnsafeMutableRawPointer? = L.tolightuserdata(-1) {
            XCTAssertNil(gotlud)
        } else {
            XCTFail()
        }
        XCTAssertTrue(L.tolightuserdata(-1) == .some(.none))
        XCTAssertFalse(L.tolightuserdata(-1) == nil)
        let tovalueNullLud: UnsafeMutableRawPointer? = L.tovalue(-1)
        XCTAssertNil(tovalueNullLud)
        let tovalueOptNullLud: UnsafeMutableRawPointer?? = L.tovalue(-1)
        XCTAssertFalse(tovalueOptNullLud == nil)

        L.pop()

        lua_newuserdata(L, 4)
        // Check we don't allow full userdata to be returned
        XCTAssertTrue(L.tolightuserdata(-1) == nil)
    }

    func test_ref() {
        var ref: LuaValue! = L.ref(any: "hello")
        XCTAssertEqual(ref.type, .string)
        XCTAssertEqual(ref.toboolean(), true)
        XCTAssertEqual(ref.tostring(), "hello")
        XCTAssertEqual(L.gettop(), 0)

        ref = LuaValue()
        XCTAssertEqual(ref.type, .nil)

        ref = L.ref(any: nil)
        XCTAssertEqual(ref.type, .nil)

        // Check it can correctly keep hold of a ref to a Swift object
        var deinited = 0
        var obj: DeinitChecker? = DeinitChecker { deinited += 1 }
        L.register(Metatable<DeinitChecker>(close: .synthesize))
        ref = L.ref(any: obj!)

        XCTAssertIdentical(ref.toany() as? AnyObject, obj)

        XCTAssertNotNil(ref)
        obj = nil
        XCTAssertEqual(deinited, 0) // reference from userdata on stack
        L.settop(0)
        L.collectgarbage()
        XCTAssertEqual(deinited, 0) // reference from ref
        ref = nil
        L.collectgarbage()
        XCTAssertEqual(deinited, 1) // no more references
    }

    func test_ref_scoping() {
        var ref: LuaValue! = L.ref(any: "hello")
        XCTAssertEqual(ref.type, .string) // shut up compiler complaining about unused ref
        L.close()
        XCTAssertNil(ref.internal_get_L())
        // The act of nilling this will cause a crash if the close didn't nil ref.L
        ref = nil

        L = nil // make sure teardown doesn't try to close it again
    }

    func test_ref_get() throws {
        let strType = try L.globals["type"].pcall("foo").tostring()
        XCTAssertEqual(strType, "string")

        let nilType = try L.globals.get("type").pcall(nil).tostring()
        XCTAssertEqual(nilType, "nil")

        let arrayRef = L.ref(any: [11,22,33,44])
        XCTAssertEqual(arrayRef[1].toint(), 11)
        XCTAssertEqual(arrayRef[4].toint(), 44)
        XCTAssertEqual(try arrayRef.len, 4)
    }

    func test_ref_get_complexMetatable() throws {
        struct IndexableValue {}
        L.register(Metatable<IndexableValue>(
            index: .function { L in
                return 1 // Ie just return whatever the key name was
            }
        ))
        let ref = L.ref(any: IndexableValue())
        XCTAssertEqual(try ref.get("woop").tostring(), "woop")

        // Now make ref the __index of another userdata
        // This didn't work with the original implementation of checkIndexable()

        lua_newuserdata(L, 4) // will become udref
        lua_newtable(L) // udref's metatable
        L.rawset(-1, key: "__index", value: ref)
        lua_setmetatable(L, -2) // pops metatable
        // udref is now a userdata with an __index metafield that points to ref
        let udref = L.ref(index: -1)
        XCTAssertEqual(try udref.get("woop").tostring(), "woop")
    }

    func test_ref_chaining() throws {
        L.openLibraries([.string])
        let result = try L.globals.get("type").pcall(L.globals["print"]).pcall(member: "sub", 1, 4).tostring()
        XCTAssertEqual(result, "func")
    }

    func test_ref_errors() throws {
        L.openLibraries([.string])

        XCTAssertThrowsError(try L.globals["nope"](), "", { err in
            XCTAssertEqual(err as? LuaValueError, .nilValue)
        })

        XCTAssertThrowsError(try L.globals["string"](), "", { err in
            XCTAssertEqual(err as? LuaValueError, .notCallable)
        })

        XCTAssertThrowsError(try L.globals["type"].get("nope"), "", { err in
            XCTAssertEqual(err as? LuaValueError, .notIndexable)
        })

        XCTAssertThrowsError(try L.globals.pcall(member: "nonexistentfn"), "", { err in
            XCTAssertEqual(err as? LuaValueError, .nilValue)
        })

        XCTAssertThrowsError(try L.globals["type"].pcall(member: "nonexistentfn"), "", { err in
            XCTAssertEqual(err as? LuaValueError, .notIndexable)
        })
    }

    func test_ref_set() throws {
        L.globals["foo"] = L.ref(any: 123)
        XCTAssertEqual(L.globals["foo"].toint(), 123)
    }

    func test_nil() throws {
        XCTAssertEqual(L.type(1), nil)
        L.pushnil()
        XCTAssertEqual(L.type(1), .nil)
        L.pop()
        XCTAssertEqual(L.type(1), nil)

        L.getglobal("select")
        let sel1: Bool? = try L.pcall(1, false, nil, "str")
        XCTAssertEqual(sel1, false)
        L.getglobal("select")
        let sel2: Any? = try L.pcall(2, false, nil, "str")
        XCTAssertNil(sel2)
        L.getglobal("select")
        let sel3: String? = try L.pcall(3, false, nil, "str")
        XCTAssertEqual(sel3, "str")
    }

    func test_tovalue_data() {
        L.push("abc")
        let byteArray: [UInt8]? = L.tovalue(1)
        XCTAssertEqual(byteArray, [0x61, 0x62, 0x63])

        let str: String? = L.tovalue(1)
        XCTAssertEqual(str, "abc")

#if !LUASWIFT_NO_FOUNDATION
        let data: Data? = L.tovalue(1)
        XCTAssertEqual(data, Data([0x61, 0x62, 0x63]))
#endif
    }

    func test_tovalue_number() {
        L.push(3.0) // 1: A double but integer representable
        L.push(Double.pi) // 2: A double

        let intVal: Int? = L.tovalue(1)
        XCTAssertEqual(intVal, 3)

        // This is a test for tovalue(_:type:) really
        XCTAssertEqual(Int8(try XCTUnwrap(L.tovalue(1, type: Int.self))), 3)

        let integerVal: lua_Integer? = L.tovalue(1)
        XCTAssertEqual(integerVal, 3)

        let int64Val: Int64? = L.tovalue(1)
        XCTAssertEqual(int64Val, 3)

        // Because lua_tointeger() succeeded on the value, toany will return it as a lua_Integer, thus checking we can
        // retrieve it as a Double is not a given.
        let doubleVal: Double? = L.tovalue(1)
        XCTAssertEqual(doubleVal, 3.0)

        // Downcasting to a smaller integer type IS now expected to work, because while `Int as? Int8` is not something
        // Swift lets you do, `Int as? AnyHashable as? Int8` _does_, and toany casts all integers to AnyHashable before
        // returning them
        let smolInt: Int8? = L.tovalue(1)
        XCTAssertEqual(smolInt, 3)

        // We should not allow truncation of something not representable as an integer
        let nope: Int? = L.tovalue(2)
        XCTAssertNil(nope)

        // Check there is no loss of precision in round-tripping an irrational float
        XCTAssertEqual(L.tovalue(2), Double.pi)
    }

    func test_math_pi() throws {
        // Given these are defined in completely different unrelated places, I'm slightly surprised their definitions
        // agree exactly.
        L.openLibraries([.math])
        let mathpi: Double = try XCTUnwrap(L.globals["math"]["pi"].tovalue())
        XCTAssertEqual(mathpi, Double.pi)
    }

    func test_tovalue_anynil() {
        L.push(true)
        let anyTrue: Any? = L.tovalue(1)
        XCTAssertEqual(anyTrue as? Bool?, true)
        L.pop()

        L.pushnil()
        let anyNil: Any? = L.tovalue(1)
        XCTAssertNil(anyNil)

        let anyHashableNil: AnyHashable? = L.tovalue(1)
        XCTAssertNil(anyHashableNil)

        let optionalAnyHashable = L.tovalue(1, type: AnyHashable?.self)
        // This, like any request to convert nil to an optional type, should succeed
        XCTAssertEqual(optionalAnyHashable, .some(.none))
    }

    func test_tovalue_optionals() {
        L.pushnil() // 1
        L.push(123) // 2
        L.push("abc") // 3
        L.push([123, 456]) // 4
        L.push(["abc", "def"]) // 5

        // The preferred representation casting nil to nested optionals is with "the greatest optional depth possible"
        // according to https://github.com/apple/swift/blob/main/docs/DynamicCasting.md#optionals but let's check that
        let nilint: Int? = nil
        // One further check that these don't actually compare equal, otherwise our next check won't necessarily catch anything...
        XCTAssertNotEqual(Optional<Optional<Optional<Int>>>.some(.some(.none)), Optional<Optional<Optional<Int>>>.some(.none))
        // Now check as Int??? is what we expect
        XCTAssertEqual(nilint as Int???, Optional<Optional<Optional<Int>>>.some(.some(.none)))

        // Now check tovalue with nil behaves the same as `as?`
        XCTAssertEqual(L.tovalue(1, type: Int.self), Optional<Int>.none)
        XCTAssertEqual(L.tovalue(1, type: Int?.self), Optional<Optional<Int>>.some(.none))
        XCTAssertEqual(L.tovalue(1, type: Int??.self), Optional<Optional<Optional<Int>>>.some(.some(.none)))

        // Now check we can cast a Lua int to any depth of Optional Int
        XCTAssertEqual(L.tovalue(2, type: Int.self), Optional<Int>.some(123))
        XCTAssertEqual(L.tovalue(2, type: Int?.self), Optional<Optional<Int>>.some(.some(123)))
        XCTAssertEqual(L.tovalue(2, type: Int??.self), Optional<Optional<Optional<Int>>>.some(.some(.some(123))))

        // A Lua int should never succeed in casting to any level of String optional
        XCTAssertEqual(L.tovalue(2, type: String.self), Optional<String>.none)
        XCTAssertEqual(L.tovalue(2, type: String?.self), Optional<Optional<String>>.none)
        XCTAssertEqual(L.tovalue(2, type: String??.self), Optional<Optional<Optional<String>>>.none)

        // The same 6 checks should also hold true for string:

        // Check we can cast a Lua string to any depth of Optional String
        XCTAssertEqual(L.tovalue(3, type: String.self), Optional<String>.some("abc"))
        XCTAssertEqual(L.tovalue(3, type: String?.self), Optional<Optional<String>>.some(.some("abc")))
        XCTAssertEqual(L.tovalue(3, type: String??.self), Optional<Optional<Optional<String>>>.some(.some(.some("abc"))))

        // A Lua string should never succeed in casting to any level of Int optional
        XCTAssertEqual(L.tovalue(3, type: Int.self), Optional<Int>.none)
        XCTAssertEqual(L.tovalue(3, type: Int?.self), Optional<Optional<Int>>.none)
        XCTAssertEqual(L.tovalue(3, type: Int??.self), Optional<Optional<Optional<Int>>>.none)

        // Check we can cast a Lua string to any depth of Optional [UInt8]
        let bytes: [UInt8] = [0x61, 0x62, 0x63]
        XCTAssertEqual(L.tovalue(3, type: [UInt8].self), Optional<[UInt8]>.some(bytes))
        XCTAssertEqual(L.tovalue(3, type: [UInt8]?.self), Optional<Optional<[UInt8]>>.some(.some(bytes)))
        XCTAssertEqual(L.tovalue(3, type: [UInt8]??.self), Optional<Optional<Optional<[UInt8]>>>.some(.some(.some(bytes))))

        // Check we can cast a Lua string to any depth of Optional Data
        let data = Data(bytes)
        XCTAssertEqual(L.tovalue(3, type: Data.self), Optional<Data>.some(data))
        XCTAssertEqual(L.tovalue(3, type: Data?.self), Optional<Optional<Data>>.some(.some(data)))
        XCTAssertEqual(L.tovalue(3, type: Data??.self), Optional<Optional<Optional<Data>>>.some(.some(.some(data))))

        // Check we can cast an array table to any depth of Optional Array
        XCTAssertEqual(L.tovalue(4, type: Array<Int>.self), Optional<Array<Int>>.some([123, 456]))
        XCTAssertEqual(L.tovalue(4, type: Array<Int>?.self), Optional<Optional<Array<Int>>>.some(.some([123, 456])))
        XCTAssertEqual(L.tovalue(4, type: Array<Int>??.self), Optional<Optional<Optional<Array<Int>>>>.some(.some(.some([123, 456]))))

        // An array table should never succeed in casting to any level of Dictionary optional
        XCTAssertEqual(L.tovalue(4, type: Dictionary<String, Int>.self), Optional<Dictionary<String, Int>>.none)
        XCTAssertEqual(L.tovalue(4, type: Dictionary<String, Int>?.self), Optional<Optional<Dictionary<String, Int>>>.none)
        XCTAssertEqual(L.tovalue(4, type: Dictionary<String, Int>??.self), Optional<Optional<Optional<Dictionary<String, Int>>>>.none)
    }

    func test_tovalue_any() throws {
        let asciiByteArray: [UInt8] = [0x64, 0x65, 0x66]
        let nonUtf8ByteArray: [UInt8] = [0xFF, 0xFF, 0xFF]
        let intArray = [11, 22, 33]
        let luaIntegerArray: [lua_Integer] = [11, 22, 33]
        let intArrayAsDict = [1: 11, 2: 22, 3: 33]
        let intArrayAsLuaIntegerDict: [lua_Integer: lua_Integer] = [1: 11, 2: 22, 3: 33]
        let stringIntDict = ["aa": 11, "bb": 22, "cc": 33]
        let stringLuaIntegerDict: [String: lua_Integer] = ["aa": 11, "bb": 22, "cc": 33]
        let stringArrayIntDict: Dictionary<[String], Int> = [ ["abc"]: 123 ]
        let whatEvenIsThis: Dictionary<Dictionary<String, Dictionary<Int, Int>>, Int> = [ ["abc": [123: 456]]: 789 ]

        L.push("abc") // 1
        L.push(asciiByteArray) // 2
        L.push(nonUtf8ByteArray) // 3
        L.push(intArray) // 4
        L.push(stringIntDict) // 5
        L.push(stringArrayIntDict) // 6
        L.push(whatEvenIsThis) // 7

        // Test that string defaults to String if possible, otherwise [UInt8]
        XCTAssertEqual(L.tovalue(1, type: Any.self) as? String, "abc")
        XCTAssertEqual(L.tovalue(1, type: AnyHashable.self) as? String, "abc")
        XCTAssertEqual(L.tovalue(2, type: Any.self) as? String, "def")
        XCTAssertEqual(L.tovalue(2, type: AnyHashable.self) as? String, "def")
        XCTAssertEqual(L.tovalue(3, type: Any.self) as? [UInt8], nonUtf8ByteArray)
        XCTAssertEqual(L.tovalue(3, type: AnyHashable.self) as? [UInt8], nonUtf8ByteArray)

        XCTAssertEqual(L.tovalue(4, type: Any.self) as? Dictionary<lua_Integer, lua_Integer>, intArrayAsLuaIntegerDict)
        XCTAssertEqual((L.tovalue(4, type: Any.self) as? Dictionary<AnyHashable, Any>)?.luaTableToArray() as? Array<lua_Integer>, luaIntegerArray)
#if !LUASWIFT_ANYHASHABLE_BROKEN
        XCTAssertEqual(L.tovalue(4, type: Dictionary<AnyHashable, Any>.self) as? Dictionary<Int, Int>, intArrayAsDict)
        XCTAssertEqual(L.tovalue(4, type: Any.self) as? Dictionary<Int, Int>, intArrayAsDict)
        XCTAssertEqual((L.tovalue(4, type: Any.self) as? Dictionary<AnyHashable, Any>)?.luaTableToArray() as? Array<Int>, intArray)
#endif

        XCTAssertEqual(L.tovalue(5, type: Dictionary<AnyHashable, Any>.self) as? Dictionary<String, lua_Integer>, stringLuaIntegerDict)
        XCTAssertEqual(L.tovalue(5, type: Any.self) as? Dictionary<String, lua_Integer>, stringLuaIntegerDict)
#if !LUASWIFT_ANYHASHABLE_BROKEN
        XCTAssertEqual(L.tovalue(5, type: Dictionary<AnyHashable, Any>.self) as? Dictionary<String, Int>, stringIntDict)
        XCTAssertEqual(L.tovalue(5, type: Any.self) as? Dictionary<String, Int>, stringIntDict)
#endif

        let tableKeyDict = L.tovalue(6, type: Dictionary<[String], Int>.self)
        XCTAssertEqual(tableKeyDict, stringArrayIntDict)

        // Yes this really is a type that has a separate code path - a Dictionary value with a AnyHashable constraint
        let theElderValue = L.tovalue(7, type: Dictionary<Dictionary<String, Dictionary<Int, Int>>, Int>.self)
        XCTAssertEqual(theElderValue, whatEvenIsThis)

        // tables _can_ now be returned as AnyHashable - they will always convert to Dictionary<AnyHashable, AnyHashable>.
        let anyHashableDict: AnyHashable = try XCTUnwrap(L.tovalue(5))
        XCTAssertEqual(anyHashableDict as? [String: lua_Integer], stringLuaIntegerDict)
        XCTAssertEqual((L.tovalue(4, type: AnyHashable.self) as? Dictionary<AnyHashable, AnyHashable>)?.luaTableToArray() as? Array<lua_Integer>, luaIntegerArray)
#if !LUASWIFT_ANYHASHABLE_BROKEN
        XCTAssertEqual(anyHashableDict as? [String: Int], stringIntDict)
        XCTAssertEqual((L.tovalue(4, type: AnyHashable.self) as? Dictionary<AnyHashable, AnyHashable>)?.luaTableToArray() as? Array<Int>, intArray)
#endif
    }

    // There are 2 basic Any pathways to worry about, which are tovalue<Any> and tovalue<AnyHashable>.
    // Then there are LuaTableRef.doResolveArray and LuaTableRef.doResolveDict which necessarily don't use tovalue,
    // meaning Array<Any>, Array<AnyHashable>, Dictionary<AnyHashable, Any> and Dictionary<AnyHashable, AnyHashable>
    // all need testing too. And for each of *those*, we need to test with string, table and something-that's-neither
    // datatypes.

    func test_tovalue_any_int() {
        L.push(123)
        let anyVal: Any? = L.tovalue(1)
        XCTAssertNotNil(anyVal as? lua_Integer)
#if !LUASWIFT_ANYHASHABLE_BROKEN
        XCTAssertNotNil(anyVal as? Int)
#endif
        let anyHashable: AnyHashable? = L.tovalue(1)
        XCTAssertNotNil(anyHashable as? lua_Integer)
#if !LUASWIFT_ANYHASHABLE_BROKEN
        XCTAssertNotNil(anyHashable as? Int)
#endif
    }

    func test_tovalue_any_string() {
        L.push("abc")
        let anyVal: Any? = L.tovalue(-1)
        XCTAssertEqual(anyVal as? String, "abc")
        let anyHashable: AnyHashable? = L.tovalue(-1)
        XCTAssertEqual(anyHashable as? String, "abc")
    }

    func test_tovalue_any_stringarray() throws {
        let stringArray = ["abc"]
        L.push(stringArray)
        let anyArray: Array<Any> = try XCTUnwrap(L.tovalue(1))
        XCTAssertEqual(anyArray as? [String], stringArray)

        let anyHashableArray: Array<AnyHashable> = try XCTUnwrap(L.tovalue(1))
        XCTAssertEqual(anyHashableArray as? [String], stringArray)
    }

    func test_tovalue_luavaluearray() throws {
        L.newtable()
        L.rawset(-1, key: 1, value: 123)
        L.rawset(-1, key: 2, value: "abc")
        let array: Array<LuaValue> = try XCTUnwrap(L.tovalue(1))
        XCTAssertEqual(array[0].tovalue(), 123)
        XCTAssertEqual(array[1].tovalue(), "abc")
    }

    func test_tovalue_any_stringdict() throws {
        L.push(["abc": "def"])

        let anyDict: Dictionary<AnyHashable, Any> = try XCTUnwrap(L.tovalue(1))
        XCTAssertEqual(anyDict as? [String: String], ["abc": "def"])

        // Check T=Any does in fact behave the same as T=Dictionary<AnyHashable, Any>
        let anyVal: Any = try XCTUnwrap(L.tovalue(1))
        XCTAssertTrue(type(of: anyVal) == Dictionary<AnyHashable, Any>.self)
        XCTAssertEqual(anyVal as? [String: String], ["abc": "def"])

    }

    func test_tovalue_any_stringintdict() throws {
        L.push(["abc": 123])

        let anyDict: Dictionary<AnyHashable, Any> = try XCTUnwrap(L.tovalue(1))
        XCTAssertEqual(anyDict as? [String: lua_Integer], ["abc": 123])
#if !LUASWIFT_ANYHASHABLE_BROKEN
        XCTAssertEqual(anyDict as? [String: Int], ["abc": 123])
#endif

        // Check T=Any does in fact behave the same as T=Dictionary<AnyHashable, Any>
        let anyVal: Any = try XCTUnwrap(L.tovalue(1))
        XCTAssertTrue(type(of: anyVal) == Dictionary<AnyHashable, Any>.self)
        XCTAssertEqual(anyVal as? [String: lua_Integer], ["abc": 123])
#if !LUASWIFT_ANYHASHABLE_BROKEN
        XCTAssertEqual(anyVal as? [String: Int], ["abc": 123])
#endif
    }

    func test_tovalue_stringanydict() throws {
        L.newtable()
        L.rawset(-1, key: "abc", value: "def")
        L.rawset(-1, key: "123", value: 456)
        let anyDict: Dictionary<String, Any> = try XCTUnwrap(L.tovalue(1))
        XCTAssertEqual(anyDict["abc"] as? String, "def")
        XCTAssertEqual(anyDict["123"] as? lua_Integer, 456)
#if !LUASWIFT_ANYHASHABLE_BROKEN
        XCTAssertEqual(anyDict["123"] as? Int, 456)
#endif
    }

    func test_tovalue_luavalue() throws {
        L.push("abc")
        L.push(123)
        L.push([123])
        L.push(["abc": 123])

        XCTAssertEqual(L.tovalue(1, type: LuaValue.self)?.tostring(), "abc")
        XCTAssertEqual(L.tovalue(2, type: LuaValue.self)?.toint(), 123)

        XCTAssertEqual(try XCTUnwrap(L.tovalue(3, type: LuaValue.self)?.type), .table)
        let luaValueArray: [LuaValue] = try XCTUnwrap(L.tovalue(3))
        XCTAssertEqual(luaValueArray[0].toint(), 123)
    }

    func test_tovalue_fndict() {
        L.newtable()
        L.push(L.globals["print"])
        L.push(true)
        L.rawset(-3)
        // We now have a table of [lua_CFunction : Bool] except that lua_CFunction isn't Hashable

        let anyanydict = L.tovalue(1, type: [AnyHashable: Any].self)
        // We expect this to fail due to the lua_CFunction not being Hashable
        XCTAssertNil(anyanydict)
    }

    func test_tovalue_luaclosure() throws {
        let closure: LuaClosure = { _ in return 0 }
        L.push(closure)
        XCTAssertNotNil(L.tovalue(1, type: LuaClosure.self))
        L.pop()

        L.newtable()
        L.push(closure)
        L.rawset(-2, key: 1)
        let closureArray: [LuaClosure] = try XCTUnwrap(L.tovalue(1))
        XCTAssertEqual(closureArray.count, 1)
    }

    func test_tovalue_userdata() throws {
        L.push(lightuserdata: nil) // 1
        let m = malloc(4)
        defer {
            free(m)
        }
        L.push(lightuserdata: m) // 2
        let udata = lua_newuserdata(L, 12) // 3
        struct Foo { let bar = 0 }
        L.register(Metatable<Foo>())
        L.push(userdata: Foo()) // 4
        L.pushnil() // 5

        // I hate that this succeeds...
        XCTAssertEqual(L.tovalue(5, type: UnsafeMutableRawPointer?.self), Optional<UnsafeMutableRawPointer>.none)

        XCTAssertNil(L.tovalue(1, type: UnsafeMutableRawPointer.self))
        XCTAssertNil(L.tovalue(1, type: UnsafeRawPointer.self))
        XCTAssertNotNil(L.tovalue(1, type: Any.self))
        XCTAssertNotNil(L.tovalue(1, type: AnyHashable.self))

        XCTAssertEqual(L.tovalue(2, type: UnsafeMutableRawPointer.self), m)
        XCTAssertEqual(L.tovalue(2, type: UnsafeRawPointer.self), UnsafeRawPointer(m))
        XCTAssertEqual(L.tovalue(2, type: Any.self) as? UnsafeMutableRawPointer, m)
        XCTAssertNotNil(L.tovalue(2, type: AnyHashable.self) as? UnsafeMutableRawPointer)
        XCTAssertNil(L.tovalue(2, type: Any.self) as? UnsafeRawPointer)
        XCTAssertNil(L.tovalue(2, type: AnyHashable.self) as? UnsafeRawPointer)

        XCTAssertEqual(L.tovalue(3), udata)
        XCTAssertEqual(L.tovalue(3, type: UnsafeRawPointer.self), UnsafeRawPointer(udata))
        XCTAssertEqual(L.tovalue(3, type: Any.self) as? UnsafeMutableRawPointer, udata)
        XCTAssertEqual(L.tovalue(3, type: AnyHashable.self) as? UnsafeMutableRawPointer, udata)
        XCTAssertNil(L.tovalue(3, type: Any.self) as? UnsafeRawPointer)
        XCTAssertNil(L.tovalue(3, type: AnyHashable.self) as? UnsafeRawPointer)

        XCTAssertNotNil(L.tovalue(4, type: Foo.self))
        // Should fail because 4 is not a foreign userdata
        XCTAssertNil(L.tovalue(4, type: UnsafeMutableRawPointer.self))
        XCTAssertNil(L.tovalue(4, type: UnsafeRawPointer.self))
    }

// #if !LUASWIFT_NO_FOUNDATION
//     func test_tovalue_table_perf_int_array() {
//         L.newtable()
//         // Add an extra zero to this (for 1000000) to make the test more obvious
//         for i in 1 ..< 1000000 {
//             L.rawset(-1, key: i, value: i)
//         }
//         measure {
//             let _: [Int] = L.tovalue(-1)!
//         }
//     }

//     func test_tovalue_table_perf_data_array() {
//         L.newtable()
//         // Add an extra zero to this (for 1000000) to make the test more obvious
//         for i in 1 ..< 1000000 {
//             L.rawset(-1, key: i, value: "abc")
//         }
//         measure {
//             let _: [Data] = L.tovalue(-1)!
//         }
//     }

//     func test_tovalue_table_perf_int_dict() {
//         L.newtable()
//         // Add an extra zero to this (for 1000000) to make the test more obvious
//         for i in 1 ..< 1000000 {
//             L.rawset(-1, key: i, value: i)
//         }
//         measure {
//             let _: Dictionary<Int, Int> = L.tovalue(-1)!
//         }
//     }

//     func test_tovalue_table_perf_data_dict() {
//         L.newtable()
//         // Add an extra zero to this (for 1000000) to make the test more obvious
//         for i in 1 ..< 1000000 {
//             L.rawset(-1, key: "\(i)", value: "abc")
//         }
//         measure {
//             let _: Dictionary<Data, Data> = L.tovalue(-1)!
//         }
//     }

// #endif

    func test_load_file() {
        XCTAssertThrowsError(try L.load(file: "nopemcnopeface"), "", { err in
            XCTAssertEqual(err as? LuaLoadError, .fileError("cannot open nopemcnopeface: No such file or directory"))
        })
        XCTAssertEqual(L.gettop(), 0)
    }

    func test_load() throws {
        try L.dostring("return 'hello world'")
        XCTAssertEqual(L.tostring(-1), "hello world")

        let asArray: [UInt8] = "return 'hello world'".map { $0.asciiValue! }
        try L.load(data: asArray, name: "Hello", mode: .text)
        try L.pcall(nargs: 0, nret: 1)
        XCTAssertEqual(L.tostring(-1), "hello world")

        XCTAssertThrowsError(try L.load(string: "woop woop"), "", { err in
            let expected = #"[string "woop woop"]:1: syntax error near 'woop'"#
            // Note, casting err directly to CustomStringConvertible does _not_ pick up the LuaLoadError impl when
            // testing on Linux...
            let loadErr = err as? LuaLoadError
            XCTAssertEqual(loadErr, .parseError(expected))
            XCTAssertEqual((loadErr as CustomStringConvertible?)?.description, "LuaLoadError.parseError(\(expected))")
            XCTAssertEqual(loadErr?.localizedDescription, "LuaLoadError.parseError(\(expected))")
        })

        XCTAssertThrowsError(try L.load(string: "woop woop", name: "@nope.lua"), "", { err in
            let expected = "nope.lua:1: syntax error near 'woop'"
            XCTAssertEqual((err as? LuaLoadError), .parseError(expected))
        })
    }

    func test_setModules() throws {
        let mod = """
            -- print("Hello from module land!")
            return "hello"
            """.map { $0.asciiValue! }
        // To be extra awkward, we call addModules before opening package (which sets up the package loaders) to
        // make sure that our approach works with that
        L.setModules(["test": mod], mode: .text)
        L.openLibraries([.package])
        let ret = try L.globals["require"]("test")
        XCTAssertEqual(ret.tostring(), "hello")
    }

    func test_lua_sources() throws {
        XCTAssertNotNil(lua_sources["testmodule1"])
        L.openLibraries([.package])
        L.setModules(lua_sources)
        try L.load(string: "return require('testmodule1')")
        try L.pcall(nargs: 0, nret: 1)
        XCTAssertEqual(L.tostring(-1, key: "hello"), "world")
        L.rawget(-1, key: "foo")
        let info = L.getTopFunctionInfo(what: [.source])
        // Check we're not leaking build machine info into the function debug info
        XCTAssertEqual(info.source, "@testmodule1.lua")
        XCTAssertEqual(info.short_src, "testmodule1.lua")
    }

    func test_nested_lua_sources() throws {
        L.openLibraries([.package])
        L.setModules(lua_sources)

        func checkModule(_ name: String) throws {
            XCTAssertNotNil(lua_sources[name])
            try L.load(string: "return require('\(name)')")
            try L.pcall(nargs: 0, nret: 1)
            XCTAssertEqual(L.tostring(-1, key: "name"), name)
            try L.get(-1, key: "fn")
            let info = L.getTopFunctionInfo(what: [.source])
            // Check we're not leaking build machine info into the function debug info
            let expectedDisplayName = name.replacingOccurrences(of: ".", with: "/") + ".lua"
            XCTAssertEqual(info.source, "@\(expectedDisplayName)")
            XCTAssertEqual(info.short_src, expectedDisplayName)
        }

        try checkModule("nesttest.module")
        try checkModule("nesttest.awk%ward")
        try checkModule("nesttest.subdir.sub2.module")

        // Since this is an empty _.lua module, it should not appear in lua_sources
        XCTAssertNil(lua_sources["nesttest.subdir._"])
    }

    func test_flattened_lua_sources() throws {
        L.openLibraries([.package])

        var new_sources: [String: [UInt8]] = [:]
        for (k, v) in lua_sources {
            let modName = String(k.split(separator: ".").last!)
            new_sources[modName] = v
        }
        L.setModules(new_sources)

        func checkModule(_ name: String) throws {
            try L.load(string: "return require('\(name)')")
            try L.pcall(nargs: 0, nret: 1)
            XCTAssertEqual(L.tostring(-1, key: "name")?.hasSuffix(name), true)
        }

        try checkModule("awk%ward")
    }

    func test_lua_sources_requiref() throws {
        let lua_sources = [
            "test": """
                -- print("Hello from module land!")
                return "hello"
                """.map { $0.asciiValue! }
        ]
        try L.requiref(name: "test") {
            try L.load(data: lua_sources["test"]!, name: "test", mode: .text)
        }
        XCTAssertEqual(L.gettop(), 0)
        XCTAssertEqual(L.globals["test"].tostring(), "hello")
    }

    func test_len() throws {
        L.push(1234) // 1
        L.push("woop") // 2
        L.push([11, 22, 33, 44, 55]) // 3
        lua_newtable(L) // mt for 3
        L.setfuncs([
            "__len": { (L: LuaState!) -> CInt in
                L.push(999)
                return 1
            },
        ])
        lua_setmetatable(L, -2)

        class Foo {}
        L.register(Metatable<Foo>(
            len: .closure { L in
                L.push(42)
                return 1
            }
        ))
        L.push(userdata: Foo()) // 4
        L.pushnil() // 5

        XCTAssertNil(L.rawlen(1))
        XCTAssertEqual(L.rawlen(2), 4)
        XCTAssertEqual(L.rawlen(3), 5)
        XCTAssertEqual(L.rawlen(4), lua_Integer(MemoryLayout<Any>.size))
        XCTAssertEqual(L.rawlen(5), nil)

        XCTAssertNil(try L.len(1))
        XCTAssertEqual(try L.len(2), 4)
        let top = L.gettop()
        XCTAssertEqual(try L.len(3), 999) // len of 3 is different to rawlen thanks to metatable
        XCTAssertEqual(L.gettop(), top)
        XCTAssertEqual(L.absindex(-3), 3)
        XCTAssertEqual(try L.len(-3), 999) // -3 is 3 here
        XCTAssertEqual(try L.len(4), 42)
        XCTAssertEqual(try L.len(5), nil)

        XCTAssertThrowsError(try L.ref(index: 1).len, "", { err in
            XCTAssertEqual(err as? LuaValueError, .noLength)
        })
        XCTAssertEqual(try L.ref(index: 2).len, 4)
        XCTAssertEqual(try L.ref(index: 3).len, 999)
        XCTAssertEqual(try L.ref(index: 4).len, 42)
        XCTAssertThrowsError(try L.ref(index: 5).len, "", { err in
            XCTAssertEqual(err as? LuaValueError, .nilValue)
        })
    }

    func test_codable() throws {
        // Tests the round trip through push(encodable:) and back through todecodable()
        func check<T>(_ value: T) throws where T: Codable & Equatable {
            try L.push(encodable: value)
            defer {
                L.pop()
            }
            let decoded: T = try XCTUnwrap(L.todecodable(-1))
            // Sigh, NaNs are mathmatically great (probably) but computationally stupid
            if let flt = value as? any FloatingPoint, flt.isNaN {
                XCTAssertTrue((decoded as? any FloatingPoint)?.isNaN ?? false)
            } else {
                XCTAssertEqual(decoded, value)
            }
        }

        try check(0)
        try check(123)
        try check(255 as UInt8)
        try check(123.0)
        try check(123.4)
        try check(Double.nan)
        try check(Double.infinity)
        try check(-Double.infinity)
        try check(Float.nan)
        try check(Float.infinity)
        try check(-Float.infinity)
        try check(false)
        try check("café £")
        let emptyArray: [String] = []
        try check(emptyArray)
        let emptyDict: [String : Int] = [:]
        try check(emptyDict)
        try check([11, 22, 33])
        try check(["abc": 11, "def": 22, "g": 33])
        try check(Set<String>(arrayLiteral: "aaa", "bb", "c"))

        struct Foo: Equatable, Codable {
            let bar: Int
            let baz: String
        }
        let foo = Foo(bar: 1234, baz: "baaa")
        try check(foo)
        try check([foo])
        try check(["foo": foo, "bar": Foo(bar: 0, baz: "")])

        let data: [UInt8] = [0x61, 0x62, 0x63]
        try check(data)
#if !LUASWIFT_NO_FOUNDATION
        try check(Data(data))
#endif
    }

    func test_todecodable() throws {
        L.push(1234) // 1
        L.push(true) // 2
        L.push("hello") // 3
        L.push(123.456) // 4
        L.pushnil() // 5
        L.push(["hello": 123, "world": 456]) // 6
        L.push(any: ["bar": "sheep", "baz": 321, "bat": [true, false]] as [String : Any]) // 7

        struct Foo: Equatable, Codable {
            let bar: String
            let baz: Int
            let bat: [Bool]
        }

        XCTAssertEqual(L.todecodable(1, type: Int.self), 1234)
        XCTAssertEqual(L.todecodable(1, type: Int16.self), 1234)
        XCTAssertEqual(L.todecodable(1, type: Bool.self), nil)
        XCTAssertEqual(L.todecodable(2, type: Bool.self), true)
        XCTAssertEqual(L.todecodable(2, type: Int.self), nil)
        XCTAssertEqual(L.todecodable(3, type: String.self), "hello")
        XCTAssertEqual(L.todecodable(4, type: Double.self), 123.456)
        XCTAssertEqual(L.todecodable(5, type: Bool.self), nil)
        XCTAssertEqual(L.todecodable(6, type: Dictionary<String, Int>.self), ["hello": 123, "world": 456])
        XCTAssertEqual(L.todecodable(7, type: Foo.self), Foo(bar: "sheep", baz: 321, bat: [true, false]))
    }

    func test_encodable() throws {
        try L.push(encodable: 123)
        XCTAssertEqual(L.tovalue(-1), 123)
        L.pop()

        // Check uints can encode. Anything <= lua_Integer.max will encode as an integer
        let encodableUint: UInt64 = UInt64(lua_Integer.max)
        try L.push(encodable: encodableUint)
        XCTAssertTrue(L.isinteger(-1))
        L.pop()

        let top = L.gettop()
        XCTAssertThrowsError(try L.push(encodable: encodableUint + 1))
        XCTAssertEqual(L.gettop(), top) // An error during encoding should mean stack is unmodified

#if !LUASWIFT_NO_FOUNDATION
        let data = Data([0x61, 0x62, 0x63])
        try L.push(encodable: data)
        XCTAssertEqual(L.tostring(-1), "abc")
#endif

        struct Foo: Equatable, Codable {
            let bar: Int
            let baz: String
        }
        let foo = Foo(bar: 1234, baz: "baaa")
        let fooAsDict: Dictionary<AnyHashable, AnyHashable> = [
            "bar": 1234 as lua_Integer,
            "baz": "baaa"
        ]
        try L.push(encodable: foo)
        XCTAssertEqual(L.tovalue(-1, type: Dictionary<AnyHashable, AnyHashable>.self), fooAsDict)
        XCTAssertEqual(L.todecodable(-1), foo)
        L.pop()

        let arr = [foo]
        try L.push(encodable: arr)
        XCTAssertEqual(L.tovalue(-1, type: Array<Dictionary<AnyHashable, AnyHashable>>.self), [fooAsDict])
        L.pop()

        var optArr: [Int?] = [1, 2]
        try L.push(encodable: optArr)
        XCTAssertEqual(L.tovalue(-1, type: [Int].self), [1, 2])
        L.pop()
        optArr.insert(nil, at: 1)
        XCTAssertThrowsError(try L.push(encodable: optArr), "") { err in
            switch err as? EncodingError {
            case .none:
                XCTFail("expected EncodingError got \(err)")
            case .invalidValue(_, let context):
                XCTAssertEqual(context.debugDescription, "nil is not representable within arrays")
            default:
                XCTFail("expected EncodingError got \(err)")
            }
        }

        struct AllTheThings: Equatable, Codable {
            let int: Int
            let int8: Int8
            let int16: Int16
            let int32: Int32
            let int64: Int64
            let uint: UInt
            let uint8: UInt8
            let uint16: UInt16
            let uint32: UInt32
            let uint64: UInt64
            let bool: Bool
            let boolArray: [Bool]
            let str: String
            let fooArray: [Foo]
            let float: Float
            let double: Double
            let arrDict: [Dictionary<String, Set<Int>>]
        }
        let a = AllTheThings(int: 1,
                             int8: 2,
                             int16: 3,
                             int32: 4,
                             int64: 5,
                             uint: 6,
                             uint8: 7,
                             uint16: 8,
                             uint32: 9,
                             uint64: 10,
                             bool: true,
                             boolArray: [true, false],
                             str: "Yes",
                             fooArray: [Foo(bar: 11, baz: "baa")],
                             float: 12.0,
                             double: 13.1,
                             arrDict: [["foo": [123, 456], "bar": [789]]])
        try L.push(encodable: a)
        let decodeda: AllTheThings = try XCTUnwrap(L.todecodable(-1))
        XCTAssertEqual(decodeda, a)
    }

    func test_encodable_super() throws {
        // A good explanation of super encoder/decoder support here:
        // https://stackoverflow.com/questions/71495745/what-is-superencoder-for-in-unkeyedencodingcontainer-and-keyedencodingcontainerp#71498569

        class A: Codable {
            private enum CodingKeys: String, CodingKey {
                case aval
            }

            init(aval: Int) { self.aval = aval }

            required init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                self.aval = try container.decode(Int.self, forKey: .aval)
            }

            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(aval, forKey: .aval)
            }

            let aval: Int
        }

        class B: A, Equatable {
            // Just for fun let's make this encode using integer keys
            enum CodingKeys: Int, CodingKey {
                case bval
                case `super`
            }

            init(aval: Int, bval: String) {
                self.bval = bval
                super.init(aval: aval)
            }
            
            required init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                self.bval = try container.decode(String.self, forKey: .bval)
                try super.init(from: container.superDecoder(forKey: .super))
            }

            override func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(bval, forKey: .bval)
                try super.encode(to: c.superEncoder(forKey: .super))
            }
            static func == (lhs: B, rhs: B) -> Bool {
                return lhs.aval == rhs.aval && lhs.bval == rhs.bval
            }

            let bval: String
        }
        let b = B(aval: 123, bval: "def")
        try L.push(encodable: b)
        let bdict: Dictionary<AnyHashable, AnyHashable> = try XCTUnwrap(L.tovalue(-1))
        let expectedAdict: Dictionary<AnyHashable, AnyHashable> = ["aval": 123]
        let expectedBdict: Dictionary<AnyHashable, AnyHashable> = [
            B.CodingKeys.super.rawValue: expectedAdict,
            B.CodingKeys.bval.rawValue: "def"
        ]

        XCTAssertEqual(bdict, expectedBdict)

        // Now round-trip the encoded table through LuaDecoder
        let decodedb: B = try XCTUnwrap(L.todecodable(-1))
        XCTAssertEqual(decodedb, b)
    }

    func test_get_set() throws {
        L.push([11, 22, 33, 44, 55])
        // Do all accesses here with negative indexes to make sure they are handled right.

        L.push(2)
        XCTAssertEqual(L.rawget(-2), .number)
        XCTAssertEqual(L.gettop(), 2)
        XCTAssertEqual(L.toint(-1), 22)
        L.pop()
        XCTAssertEqual(L.gettop(), 1)

        L.rawget(-1, key: 3)
        XCTAssertEqual(L.toint(-1), 33)
        L.pop()
        XCTAssertEqual(L.gettop(), 1)

        L.push(2)
        try L.get(-2)
        XCTAssertEqual(L.toint(-1), 22)
        L.pop()
        XCTAssertEqual(L.gettop(), 1)

        try L.get(-1, key: 3)
        XCTAssertEqual(L.toint(-1), 33)
        L.pop()
        XCTAssertEqual(L.gettop(), 1)

        L.push(6)
        L.push(66)
        L.rawset(-3)
        XCTAssertEqual(L.gettop(), 1)
        XCTAssertEqual(L.rawlen(-1), 6)
        XCTAssertEqual(L.rawget(-1, key: 6, { L.toint($0) } ), 66)
        XCTAssertEqual(L.gettop(), 1)

        L.push(666)
        L.rawset(-2, key: 6)
        XCTAssertEqual(L.rawget(-1, key: 6, { L.toint($0) } ), 666)
        XCTAssertEqual(L.gettop(), 1)

        L.rawset(-1, key: 6, value: 6666)
        XCTAssertEqual(L.gettop(), 1)
        XCTAssertEqual(L.rawget(-1, key: 6, { L.toint($0) } ), 6666)
        XCTAssertEqual(L.gettop(), 1)

        L.push(1)
        L.push(111)
        try L.set(-3)
        XCTAssertEqual(L.rawget(-1, key: 1, { L.toint($0) } ), 111)
        XCTAssertEqual(L.gettop(), 1)

        L.push(222)
        try L.set(-2, key: 2)
        XCTAssertEqual(L.rawget(-1, key: 2, { L.toint($0) } ), 222)
        XCTAssertEqual(L.gettop(), 1)

        try L.set(-1, key: 3, value: 333)
        XCTAssertEqual(L.rawget(-1, key: 3, { L.toint($0) } ), 333)
        XCTAssertEqual(L.gettop(), 1)
    }

    func test_getinfo() throws {
        XCTAssertEqual(Set<LuaDebug.WhatInfo>.allHook, Set(LuaDebug.WhatInfo.allCases))

        var info: LuaDebug! = nil
        var whereStr: String! = nil
        try L.load(string: """
            fn = ...
            function moo(arg, arg2, arg3)
                fn()
            end
            moo()
            """, name: "=test")
        L.push(index: 1)
        L.push({ L in
            info = L.getStackInfo(level: 1)
            whereStr = L.getWhere(level: 1)
            return 0
        })
        try L.pcall(nargs: 1, nret: 0)
        XCTAssertEqual(info.name, "moo")
        XCTAssertEqual(info.namewhat, .global)
        XCTAssertEqual(info.what, .lua)
        XCTAssertEqual(info.currentline, 3)
        XCTAssertEqual(info.linedefined, 2)
        XCTAssertEqual(info.lastlinedefined, 4)
        XCTAssertEqual(info.nups, 1)
        XCTAssertEqual(info.nparams, 3)
        XCTAssertEqual(info.isvararg, false)
        XCTAssertEqual(info.function?.type, .function)
        XCTAssertEqual(info.validlines, [3, 4])
        XCTAssertEqual(info.short_src, "test")
        XCTAssertEqual(whereStr, info.short_src! + ":3: ")

        // This is getting info for the fn returned by load(file:)
        let fninfo = L.getTopFunctionInfo()
        XCTAssertEqual(fninfo.what, .main)
        XCTAssertNil(fninfo.name) // a main fn won't have a name
        XCTAssertEqual(fninfo.namewhat, .other)
        XCTAssertNil(fninfo.currentline)
    }

    func test_getinfo_stripped() throws {
        try L.load(string: """
            fn = ...
            function moo(arg, arg2, arg3)
                fn()
            end
            moo()
            """, name: "=test")
        let bytecode = L.dump(strip: true)!
        L.pop()
        try L.load(data: bytecode, name: nil, mode: .binary)
        var info: LuaDebug! = nil
        L.push({ L in
            info = L.getStackInfo(level: 1)
            return 0
        })
        try L.pcall(nargs: 1, nret: 0)

        XCTAssertEqual(info.name, "moo")
        XCTAssertEqual(info.source, "=?")
        XCTAssertEqual(info.short_src, "?")
        // Apparently stripping removes the info that makes it possible to determine moo is a global, so it reverts to
        // field.
        XCTAssertEqual(info.namewhat, .field)
        XCTAssertEqual(info.what, .lua)
        XCTAssertEqual(info.currentline, nil)
        // These line numbers are preeserved even through stripping, which I suppose makes sense given the docs say
        // "If strip is true, the binary representation **may** not include all debug information about the function, to
        // save space".
        XCTAssertEqual(info.linedefined, 2)
        XCTAssertEqual(info.lastlinedefined, 4)
        XCTAssertEqual(info.nups, 1)
        XCTAssertEqual(info.nparams, 3)
        XCTAssertEqual(info.isvararg, false)
        XCTAssertEqual(info.function?.type, .function)
        XCTAssertEqual(info.validlines, [])
    }

    func test_isinteger() {
        L.push(123)
        L.push(123.0)
        L.pushnil()
        L.push(true)

        XCTAssertTrue(L.isinteger(1))
        XCTAssertFalse(L.isinteger(2))
        XCTAssertFalse(L.isinteger(3))
        XCTAssertFalse(L.isinteger(4))
    }

#if !LUASWIFT_NO_FOUNDATION
    func test_push_NSNumber() throws {
        let n: NSNumber = 1234
        let nd: NSNumber = 1234.0
        L.push(n) // 1 - using NSNumber's Pushable
        L.push(any: n) // 2 - NSNumber as Any

        var i: Double = 1234.5678
        let ni: NSNumber = 1234.5678
        let cfn: CFNumber = CFNumberCreate(nil, .doubleType, &i)
        // CF bridging is _weird_: I cannot write L.push(cfn) ie CFNumber does not directly conform to Pushable, but
        // the conversion to Pushable will always succeed, presumably because NSNumber is Pushable?
        let cfn_pushable = try XCTUnwrap(cfn as? Pushable)
#if !os(Linux) // CF bridging seems to be entirely lacking on Linux...
        L.push(cfn as NSNumber) // 3 - CFNumber as NSNumber (Pushable)
#else
        L.pushnil()
#endif
        L.push(cfn_pushable) // 4 - CFNumber as Pushable
        L.push(any: cfn) // 5 - CFNumber as Any
        L.push(nd) // 6 - integer-representable NSNumber from a double
        L.push(ni) // 7 - non-integer-representable NSNumber

        XCTAssertTrue(L.isinteger(1))
        XCTAssertTrue(L.isinteger(6)) // NSNumber does not track the original type, ie that nd was a Double
        XCTAssertFalse(L.isinteger(7))

        XCTAssertEqual(L.toint(1), 1234)
        XCTAssertEqual(L.toint(2), 1234)
#if !os(Linux)
        XCTAssertEqual(L.tonumber(3), 1234.5678)
#endif
        XCTAssertEqual(L.tonumber(4), 1234.5678)
        XCTAssertEqual(L.tonumber(5), 1234.5678)
    }

    func test_push_NSString() {
        let ns = "hello" as NSString // This ends up as NSTaggedPointerString
        // print(type(of: ns))
        L.push(any: ns) // 1

        let s = CFStringCreateWithCString(nil, "hello", UInt32(CFStringEncodings.dosLatin1.rawValue))! // CFStringRef
        // print(type(of: s))
        L.push(any: s) // 2

        let ns2 = String(repeating: "hello", count: 100) as NSString // __StringStorage
        // print(type(of: ns2))
        L.push(any: ns2) // 3

        XCTAssertEqual(L.tostring(1), "hello")
        XCTAssertEqual(L.tostring(2), "hello")
        XCTAssertEqual(L.tostring(3), ns2 as String)
    }

    func test_push_NSData() {
        let data = Data([0x68, 0x65, 0x6C, 0x6C, 0x6F])
        let nsdata = NSData(data: data) // _NSInlineData
        let emptyNsData = NSData()
        L.push(nsdata as Data) // 1
        L.push(any: nsdata) // 2
        L.push(any: emptyNsData) // 3
        XCTAssertEqual(L.tostring(1), "hello")
        XCTAssertEqual(L.tostring(2), "hello")
        XCTAssertEqual(L.tostring(3), "")
    }

#endif

    func test_LuaClosure_upvalues() throws {
        var called = false
        L.push({ L in
            called = true
            return 0
        })
        XCTAssertEqual(called, false)
        try L.pcall()
        XCTAssertEqual(called, true)

        L.push(1234) // upvalue
        L.push({ L in
            let idx = LuaClosureWrapper.upvalueIndex(1)
            L.push(index: idx)
            return 1
        }, numUpvalues: 1)
        let ret: Int? = try L.pcall()
        XCTAssertEqual(ret, 1234)
    }

    func test_compare() throws {
        L.push(123)
        L.push(123)
        L.push(124)
        L.push("123")
        XCTAssertTrue(L.rawequal(1, 2))
        XCTAssertFalse(L.rawequal(2, 3))
        XCTAssertFalse(L.rawequal(2, 4))

        XCTAssertTrue(try L.equal(1, 2))
        XCTAssertFalse(try L.equal(1, 3))
        XCTAssertFalse(try L.equal(1, 4))

        XCTAssertFalse(try L.compare(1, 2, .lt))
        XCTAssertTrue(try L.compare(1, 2, .le))
        XCTAssertTrue(try L.compare(1, 3, .lt))

        let one = L.ref(any: 1)
        let otherone = L.ref(any: 1)
        let two = L.ref(any: 2)
        XCTAssertTrue(one.rawequal(otherone))
        XCTAssertFalse(one.rawequal(two))
        XCTAssertTrue(try one.equal(otherone))
        XCTAssertFalse(try one.equal(two))
        XCTAssertTrue(try one.compare(two, .lt)) // ie one < two
        XCTAssertFalse(try two.compare(one, .lt)) // ie two < one
    }

    func test_gc() {
        if LUA_VERSION.is54orLater() {
            var ret = L.collectorSetGenerational()
            XCTAssertEqual(ret, .incremental)
            ret = L.collectorSetIncremental(stepmul: 100)
            XCTAssertEqual(ret, .generational)
        } else {
            let ret = L.collectorSetIncremental(stepmul: 100)
            XCTAssertEqual(ret, .incremental)
        }
        XCTAssertEqual(L.collectorRunning(), true)
        L.collectgarbage(.stop)
        XCTAssertEqual(L.collectorRunning(), false)
        L.collectgarbage(.restart)
        XCTAssertEqual(L.collectorRunning(), true)

        let count = L.collectorCount()
        XCTAssertEqual(count, L.collectorCount()) // Check it's stable
        L.push("hello world")
        XCTAssertGreaterThan(L.collectorCount(), count)
    }

    func test_dump() throws {
        try! L.load(string: """
            return "called"
            """)
        let data = try XCTUnwrap(L.dump(strip: false))
        L.settop(0)
        try! L.load(data: data, name: "undumped", mode: .binary)
        try! L.pcall(nargs: 0, nret: 1)
        XCTAssertEqual(L.tostring(-1), "called")
    }

    func test_upvalues() throws {
        try L.load(string: """
            local foo, bar = 123, 456
            function baz()
                return foo or bar
            end
            """)

        try L.pcall(nargs: 0, nret: 0)
        L.getglobal("baz")

        let n = try XCTUnwrap(L.findUpvalue(index: -1, name: "foo"))
        XCTAssertEqual(n, 1)
        XCTAssertEqual(L.findUpvalue(index: -1, name: "bar"), 2)
        XCTAssertEqual(L.findUpvalue(index: -1, name: "nope"), nil)
        XCTAssertEqual(L.getUpvalues(index: -1).keys.sorted(), ["bar", "foo"])
        XCTAssertNil(L.getUpvalue(index: -1, n: 3))
        XCTAssertEqual(L.getUpvalue(index: -1, n: 1)?.value.toint(), 123)

        let updated = L.setUpvalue(index: -1, n: n, value: "abc") // modify foo
        XCTAssertTrue(updated)
        let ret: String? = try L.pcall()
        XCTAssertEqual(ret, "abc")

        L.getglobal("baz")
        L.setUpvalue(index: -1, n: n, value: .nilValue)
        let barRet: Int? = try L.pcall()
        XCTAssertEqual(barRet, 456)
    }

    func test_getLocals() throws {
        try L.load(string: """
            local foo, bar = 123, 456
            function bat(hello, world, ...)
            end
            function callNativeFn()
                local bb = bar
                local aa = foo
                nativeFn(aa, bb)
            end
            """)
        try L.pcall(nargs: 0, nret: 0)

        var localNames: [String] = []
        let closure = LuaClosureWrapper { L in
            let ret = L.withStackFrameFor(level: 1) { (frame: LuaStackFrame!) in
                XCTAssertEqual(frame.locals["aa"].toint(), 123)
                localNames = frame.localNames().map({ $0.name })
                XCTAssertEqual(localNames.sorted(), frame.locals.toDict().keys.sorted())
                return "woop"
            }
            XCTAssertEqual(ret, "woop") // Check we're returning the closure's result
            L.withStackFrameFor(level: 5) { frame in
                XCTAssertNil(frame)
            }
            return 0
        }
        L.setglobal(name: "nativeFn", value: closure)
        try L.globals["callNativeFn"].pcall()
        XCTAssertEqual(localNames, ["bb", "aa"])

        // Test getTopFunctionArguments, getTopFunctionInfo
        L.getglobal("bat")
        let args = L.getTopFunctionArguments()
        XCTAssertEqual(args, ["hello", "world"])
        let info = L.getTopFunctionInfo(what: [.paraminfo])
        XCTAssertEqual(info.isvararg, true)
        XCTAssertEqual(info.nparams, 2)

        try L.load(data: L.dump(strip: true)!, name: "=bat_stripped", mode: .binary)
        let strippedArgs = L.getTopFunctionArguments()
        let strippedInfo = L.getTopFunctionInfo(what: [.paraminfo])
        XCTAssertEqual(strippedInfo.isvararg, true)
        XCTAssertEqual(strippedInfo.nparams, 2)
        XCTAssertEqual(strippedArgs, []) // lua_getlocal() returns nothing for stripped function arguments.
    }

    func test_checkOption() throws {
        enum Foo : String {
            case foo
            case bar
            case baz
        }
        L.push("foo")
        let arg1: Foo = try XCTUnwrap(L.checkOption(1))
        XCTAssertEqual(arg1, .foo)
        let arg2: Foo = try XCTUnwrap(L.checkOption(2, default: .bar))
        XCTAssertEqual(arg2, .bar)

        L.push(123)
        XCTAssertThrowsError(try L.checkOption(2, default: Foo.foo), "", { err in
            XCTAssertEqual(err.localizedDescription, "bad argument #2 (Expected type convertible to String, got number)")
        })

        L.settop(0)
        L.setglobal(name: "nativeFn", value: .closure { L in
            let _: Foo = try L.checkOption(1)
            return 0
        })
        try! L.load(string: "nativeFn('nope')")
        XCTAssertThrowsError(try L.pcall(traceback: false), "", { err in
            XCTAssertEqual(err.localizedDescription, "bad argument #1 to 'nativeFn' (invalid option 'nope' for Foo)")
        })
    }

    func test_nan() throws {
        L.push(Double.nan)
        XCTAssertTrue(try XCTUnwrap(L.tonumber(-1)).isNaN)

        L.push(Double.infinity)
        XCTAssertTrue(try XCTUnwrap(L.tonumber(-1)).isInfinite)

        L.push(-1)
        L.push(-0.5)
        lua_arith(L, LUA_OPPOW) // -1^(-0.5) is nan
        XCTAssertTrue(try XCTUnwrap(L.tonumber(-1)).isNaN)
    }

    func test_traceback() {
        let stacktrace = """
            [string "error 'Nope'"]:1: Nope
            stack traceback:
            \t[C]: in ?
            \t[C]: in function 'error'
            \t[string "error 'Nope'"]:1: in main chunk
            """
        try! L.load(string: "error 'Nope'")
        XCTAssertThrowsError(try L.pcall()) { err in
            guard let err = err as? LuaCallError else {
                XCTFail()
                return
            }
            XCTAssertEqual(err.errorString, stacktrace.trimmingCharacters(in: .newlines))
        }
    }

    func test_traceback_tableerr() {
        try! L.load(string: "error({ err = 'doom' })")
        XCTAssertThrowsError(try L.pcall()) { err in
            guard let errVal = (err as? LuaCallError)?.errorValue else {
                XCTFail()
                return
            }
            XCTAssertEqual(errVal.type, .table)
            XCTAssertEqual(errVal["err"].tostring(), "doom")
            // Decode it, why not
            struct ErrStruct : Equatable, Decodable {
                let err: String
            }
            let errStruct: ErrStruct? = errVal.todecodable()
            XCTAssertEqual(errStruct, ErrStruct(err: "doom"))
        }
    }

    func test_traceback_userdataerr() {
        try! L.load(string: "local errObj = ...; error(errObj)")
        struct ErrStruct : Equatable {
            let err: Int
        }
        L.register(Metatable<ErrStruct>())
        L.push(userdata: ErrStruct(err: 1234))
        XCTAssertThrowsError(try L.pcall(nargs: 1, nret: 0)) { err in
            guard let errVal = (err as? LuaCallError)?.errorValue else {
                XCTFail()
                return
            }
            XCTAssertEqual(errVal.tovalue(), ErrStruct(err: 1234))
        }
    }

#if !LUASWIFT_NO_FOUNDATION // Foundation required for Bundle.module
    func test_setRequireRoot() throws {
        L.openLibraries([.package])
        let root = Bundle.module.resourceURL!.appendingPathComponent("testRequireRoot1", isDirectory: false).path
        L.setRequireRoot(root)
        try L.load(string: "return require('foo').fn")
        try L.pcall(nargs: 0, nret: 1)

        let fooinfo = L.getTopFunctionInfo()
        XCTAssertEqual(fooinfo.source, "@foo.lua")
        XCTAssertEqual(fooinfo.short_src, "foo.lua")

        try L.load(string: "return require('nested.module').fn")
        try L.pcall(nargs: 0, nret: 1)
        let nestedinfo = L.getTopFunctionInfo()
        XCTAssertEqual(nestedinfo.source, "@nested/module.lua")
        XCTAssertEqual(nestedinfo.short_src, "nested/module.lua")
    }

    func test_setRequireRoot_displayPath() throws {
        L.openLibraries([.package])
        let root = Bundle.module.resourceURL!.appendingPathComponent("testRequireRoot1", isDirectory: false).path
        L.setRequireRoot(root, displayPath: "C:/LOLWAT")
        try L.load(string: "return require('foo').fn")
        try L.pcall(nargs: 0, nret: 1)
        let info = L.getTopFunctionInfo()
        XCTAssertEqual(info.source, "@C:/LOLWAT/foo.lua")
        XCTAssertEqual(info.short_src, "C:/LOLWAT/foo.lua")
    }

    func test_setRequireRoot_requireMissing() {
        L.openLibraries([.package])
        let root = Bundle.module.resourceURL!.appendingPathComponent("testRequireRoot1", isDirectory: false).path
        L.setRequireRoot(root)
        try! L.load(string: "require 'nonexistent'", name: "=(load)")
        let expectedError = """
            (load):1: module 'nonexistent' not found:
            \tno field package.preload['nonexistent']
            \tno file 'nonexistent.lua'
            """
        XCTAssertThrowsError(try L.pcall(nargs: 0, nret: 0, traceback: false)) { err in
            guard let callerr = err as? LuaCallError else {
                XCTFail()
                return
            }
            XCTAssertEqual(callerr.errorString, expectedError)
        }
    }

#endif

    func test_setRequireRoot_nope() {
        L.openLibraries([.package])
        L.setRequireRoot(nil)
        try! L.load(string: "require 'nonexistent'", name: "=(load)")
        let expectedError = """
            (load):1: module 'nonexistent' not found:
            \tno field package.preload['nonexistent']
            """
        XCTAssertThrowsError(try L.pcall(nargs: 0, nret: 0, traceback: false)) { err in
            guard let callerr = err as? LuaCallError else {
                XCTFail()
                return
            }
            XCTAssertEqual(callerr.errorString, expectedError)
        }
    }

    func test_checkArgument() throws {
        func pcallNoPop(_ arguments: Any?...) throws {
            L.push(index: -1)
            try L.pcall(arguments: arguments)
        }

        L.push({ L in
            let _: String = try L.checkArgument(1)
            let _: String? = try L.checkArgument(2)
            return 0
        })

        try pcallNoPop("str", "str")
        try pcallNoPop("str", nil)
        XCTAssertThrowsError(try pcallNoPop(nil, nil))
        XCTAssertThrowsError(try pcallNoPop(123, nil))
        XCTAssertThrowsError(try pcallNoPop("str", 123))
        L.pop()

        L.push({ L in
            let _: Int = try L.checkArgument(1)
            let _: Int? = try L.checkArgument(2)
            return 0
        })
        try pcallNoPop(123, 123)
        try pcallNoPop(123, nil)
        XCTAssertThrowsError(try pcallNoPop(nil, nil))
        XCTAssertThrowsError(try pcallNoPop("str", nil))
        XCTAssertThrowsError(try pcallNoPop(123, "str"))
        L.pop()
    }

    func test_luaTableToArray() {
        let emptyDict: [AnyHashable: Any] = [:]
        XCTAssertEqual(emptyDict.luaTableToArray() as? [Bool], [])

#if !LUASWIFT_ANYHASHABLE_BROKEN
        let dict: [AnyHashable: Any] = [1: 111, 2: 222, 3: 333]
        XCTAssertEqual(dict.luaTableToArray() as? [Int], [111, 222, 333])
        XCTAssertEqual((dict as! [AnyHashable: AnyHashable]).luaTableToArray() as? [Int], [111, 222, 333])
#endif

        // A Lua array table shouldn't have an index 0
        let zerodict: [AnyHashable: Any] = [0: 0, 1: 111, 2: 222, 3: 333]
        XCTAssertNil(zerodict.luaTableToArray())
        XCTAssertNil((zerodict as! [AnyHashable: AnyHashable]).luaTableToArray())

        let noints: [AnyHashable: Any] = ["abc": 123, "def": 456]
        XCTAssertNil(noints.luaTableToArray())
        XCTAssertNil((noints as! [AnyHashable: AnyHashable]).luaTableToArray())

        let gap: [AnyHashable: Any] = [1: 111, 2: 222, 4: 444]
        XCTAssertNil(gap.luaTableToArray())
        XCTAssertNil((gap as! [AnyHashable: AnyHashable]).luaTableToArray())

#if !LUASWIFT_ANYHASHABLE_BROKEN
        // This should succeed because AnyHashable type-erases numbers so 2.0 should be treated just like 2
        let sneakyDouble: [AnyHashable: Any] = [1: 111, 2.0: 222, 3: 333]
        XCTAssertEqual(sneakyDouble.luaTableToArray() as? [Int], [111, 222, 333])
        XCTAssertEqual((sneakyDouble as! [AnyHashable: AnyHashable]).luaTableToArray() as? [Int], [111, 222, 333])
#endif

        let sneakyFrac: [AnyHashable: Any] = [1: 111, 2: 222, 2.5: "wat", 3: 333]
        XCTAssertNil((sneakyFrac as! [AnyHashable: AnyHashable]).luaTableToArray())
    }

    private func assertThrowsLuaArgumentError<T>(_ expr: @autoclosure () throws -> T,
                                         errorString: String,
                                         file: StaticString = #filePath,
                                         line: UInt = #line) {
        XCTAssertThrowsError(try expr(), "Expected LuaArgumentError to be thrown", file: file, line: line) { error in
            guard let argerr = error as? LuaArgumentError else {
                XCTFail("Expected thrown error to be a LuaArgumentError, not \(error)", file: file, line: line)
                return
            }
            XCTAssertEqual(argerr.errorString, errorString, file: file, line: line)
        }
    }

    func test_match() throws {
        L.openLibraries([.string])
        L.push(123) // Just to check LuaArgumentError is numbering results correctly
        let nope = try L.match(string: "asdf", pattern: "123")
        XCTAssertNil(nope)

        let hw = try L.match(string: "Hello world", pattern: "()(world)")
        XCTAssertEqual(hw, [7, "world"])

        assertThrowsLuaArgumentError(try L.match(string: "whatevs", pattern: "("),
                                     errorString: "unfinished capture")

        assertThrowsLuaArgumentError(try L.matchString(string: "abc", pattern: "()abc"),
                                     errorString: "Match result #1 is not a string")

        // Oof, the syntax to force the correct overload of matchStrings in an autoclosure is gnarly
        assertThrowsLuaArgumentError(try { () -> (String, String)? in
            try self.L.matchStrings(string: "abc", pattern: "(a)(b)(c)")
        }(), errorString: "Expected 2 match results, actually got 3")

        let m = try L.matchString(string: "Huge success!", pattern: "su%w+")
        XCTAssertEqual(m, "success")

        XCTAssertNil(try L.matchString(string: "", pattern: "nope"))

        let (h, w) = try XCTUnwrap(L.matchStrings(string: "Hello world", pattern: "(%w+) (%w+)"))
        XCTAssertEqual(h, "Hello")
        XCTAssertEqual(w, "world")

        // A single char from the UTF-8 representation of é is 0xC3 which is not on its own valid UTF-8
        assertThrowsLuaArgumentError(try L.match(string: "é", pattern: "()(.)"),
                                     errorString: "Match result #2 is not decodable using the default String encoding")
    }

    func test_gsub() throws {
        L.openLibraries([.string])
        
        XCTAssertEqual(try L.gsub(string: "hello world", pattern: "(%w+)", repl: "%1 %1"), "hello hello world world")

        XCTAssertEqual(try L.gsub(string: "hello world", pattern: "%w+", repl: "%0 %0", maxReplacements: 1),
                       "hello hello world")
        
        XCTAssertEqual(try L.gsub(string: "hello world from Lua", pattern: "(%w+)%s*(%w+)", repl: "%2 %1"),
                       "world hello Lua from")
        
        XCTAssertEqual(try L.gsub(string: "4+5 = $return 4+5$", pattern: "%$(.-)%$", repl: { s in
            try! L.dostring(s[0])
            return "\(L.tointeger(-1)!)"
        }), "4+5 = 9")

        XCTAssertEqual(try L.gsub(string: "$name-$version.tar.gz", pattern: "%$(%w+)", repl: ["name": "lua", "version": "5.4"]),
                       "lua-5.4.tar.gz")

        assertThrowsLuaArgumentError(try L.gsub(string: "3.14", pattern: "4", repl: "%2"),
                                     errorString: "invalid capture index %2")
    }

    func test_luaL_Buf() {
        L.withBuffer() { b in
            XCTAssertEqual(luaL_bufflen(b), 0)
            let ptr = luaL_prepbuffsize(b, 64)!
            XCTAssertEqual(luaL_bufflen(b), 0)
            let data: [CChar] = [1,2,3,4,5,6,7,8,9,10]
            ptr.update(from: data, count: 10)
            luaL_addsize(b, data.count)
            XCTAssertEqual(luaL_bufflen(b), 10)

            luaL_pushresult(b)
            XCTAssertEqual(L.rawlen(-1), 10)
            L.pop()
        }
    }

    func test_c_functions() {
        let closure: LuaClosure = { L in
            print("Hello")
            return 0
        }
        L.push(closure)
        L.push(closure)
        XCTAssertTrue(L.iscfunction(1))
        // The same closure pushed twice will result in different GCObjects (because LuaClosures always have upvalues)
        // hence will always be different
        XCTAssertFalse(L.rawequal(1, 2))
        L.push(index: 1)
        // Although any particular instance should compare equal to itself
        XCTAssertTrue(L.rawequal(1, 3))

        L.settop(0)

        // C Functions on the other hand should always be equal (providing they are pushed using push(function:) ofc)
        let fn: lua_CFunction = { L in
            print("Hello")
            return 0
        }
        L.push(function: fn)
        L.push(function: fn)
        XCTAssertTrue(L.iscfunction(1))
        XCTAssertTrue(L.rawequal(1, 2))
    }

    func test_anyhashable() {
        let i: Int32 = 1
        let a = i as AnyHashable
        XCTAssertEqual(a as? Int8, 1)
    }
}
