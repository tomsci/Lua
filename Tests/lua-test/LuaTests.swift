// Copyright (c) 2023 Tom Sutcliffe
// See LICENSE file for license information.

import XCTest
import Lua
import CLua

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

final class LuaTests: XCTestCase {

    var L: LuaState!

    override func setUpWithError() throws {
        L = LuaState(libraries: [])
    }

    override func tearDownWithError() throws {
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
        XCTAssertEqual(LuaState.GcMode.incremental.rawValue, LUASWIFT_GCINC)
        XCTAssertEqual(LuaState.GcMode.generational.rawValue, LUASWIFT_GCGEN)

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

    func test_LuaValue_for_ipairs_errors() throws {
        let bad_ipairs: (LuaValue) throws -> Void = { val in
            try val.for_ipairs() { _, _ in
                XCTFail("Shouldn't get here!")
                return false
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

    func test_pairs() throws {
        var dict = [
            "aaa": 111,
            "bbb": 222,
            "ccc": 333,
        ]
        L.push(dict)
        for (k, v) in L.pairs(1) {
            XCTAssertTrue(k > 1)
            XCTAssertTrue(v > 1)
            let key = try XCTUnwrap(L.tostring(k))
            let val = try XCTUnwrap(L.toint(v))
            let foundVal = dict.removeValue(forKey: key)
            XCTAssertEqual(val, foundVal)
        }
        XCTAssertTrue(dict.isEmpty) // All entries should have been removed by the pairs loop
    }

    func test_for_ipairs() throws {
        let arr = [11, 22, 33, 44, 55, 66]
        L.push(arr)
        var expected_i: lua_Integer = 0
        try L.for_ipairs(-1) { i in
            expected_i = expected_i + 1
            XCTAssertEqual(i, expected_i)
            XCTAssertEqual(L.toint(-1), arr[Int(i-1)])
            return i <= 4 // Test we can bail early
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
        try L.for_ipairs(-1) { i in
            XCTAssertEqual(i, expected_i)
            expected_i = expected_i + 1
            XCTAssertEqual(L.toint(-1), arr[Int(i-1)])
            return true
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
                return true
            }
        }
        XCTAssertThrowsError(try shouldError(), "", { err in
            XCTAssertNotNil(err as? LuaCallError)
        })
        XCTAssertEqual(last_i, 2)
    }

    func test_for_pairs_raw() throws {
        var dict = [
            "aaa": 111,
            "bbb": 222,
            "ccc": 333,
        ]
        L.push(dict)
        try L.for_pairs(1) { k, v in
            let key = try XCTUnwrap(L.tostring(k))
            let val = try XCTUnwrap(L.toint(v))
            let foundVal = dict.removeValue(forKey: key)
            XCTAssertEqual(val, foundVal)
            return true
        }
        XCTAssertTrue(dict.isEmpty) // All entries should have been removed by the pairs loop
    }

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

        try L.for_pairs(-1) { k, v in
            let key = try XCTUnwrap(L.tostring(k))
            let val = try XCTUnwrap(L.toint(v))
            let foundVal = dict.removeValue(forKey: key)
            XCTAssertEqual(val, foundVal)
            return true
        }
        XCTAssertTrue(dict.isEmpty) // All entries should have been removed by the pairs loop
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

        for (k, v) in try dictValue.pairs() {
            let key = try XCTUnwrap(k.tostring())
            let val = try XCTUnwrap(v.toint())
            let foundVal = dict.removeValue(forKey: key)
            XCTAssertEqual(val, foundVal)
        }
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

        for (k, v) in try dictValue.pairs() {
            let key = try XCTUnwrap(k.tostring())
            let val = try XCTUnwrap(v.toint())
            let foundVal = dict.removeValue(forKey: key)
            XCTAssertEqual(val, foundVal)
        }
        XCTAssertTrue(dict.isEmpty) // All entries should have been removed by the pairs loop
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

    func test_pushuserdata() {
        struct Foo : Equatable {
            let intval: Int
            let strval: String
        }
        L.register(Metatable(for: Foo.self))
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

    // Tests that objects deinit correctly when pushed with toany and GC'd by Lua
    func test_pushuserdata_instance() {
        var deinited = 0
        var val: DeinitChecker? = DeinitChecker { deinited += 1 }
        XCTAssertEqual(deinited, 0)

        L.register(Metatable(for: DeinitChecker.self))
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

        L.register(Metatable(for: DeinitChecker.self, close: .synthesize))
        XCTAssertEqual(L.gettop(), 0)

        // Avoid calling lua_toclose, to make this test still compile with Lua 5.3
        try! L.load(string: """
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
        try! L.pcall(nargs: 1, nret: 0)
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

        L.register(Metatable(for: ClosableDeinitChecker.self, close: .synthesize))
        XCTAssertEqual(L.gettop(), 0)

        // Avoid calling lua_toclose, to make this test still compile with Lua 5.3
        try! L.load(string: """
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
        try! L.pcall(nargs: 1, nret: 0)
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
        L.register(Metatable(for: SomeClass.self,
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
        try! L.load(string: "obj = ...; return obj.woop()")
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
        try! L.load(string: "obj = ...; return obj()")
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
        L.register(Metatable(for: Foo.self, eq: .synthesize))
        L.register(Metatable(for: Bar.self))
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
        L.register(Metatable(for: Foo.self, eq: .synthesize, lt: .synthesize, le: .synthesize))

        L.push(userdata: Foo(member: 111)) // 1
        L.push(userdata: Foo(member: 222)) // 2

        XCTAssertTrue(try L.compare(1, 1, .le))
        XCTAssertTrue(try L.compare(1, 1, .eq))
        XCTAssertFalse(try L.compare(1, 1, .lt))
        XCTAssertTrue(try L.compare(1, 2, .lt))
        XCTAssertFalse(try L.compare(2, 1, .le))
    }

    func test_synthesize_tostring() throws {
        struct Foo {}
        L.register(Metatable(for: Foo.self, tostring: .synthesize))
        L.push(userdata: Foo())
        let str = try XCTUnwrap(L.tostring(1, convert: true))
        XCTAssertEqual(str, "Foo()")

        struct NoTostringStruct {}
        L.register(Metatable(for: NoTostringStruct.self))
        L.push(userdata: NoTostringStruct())
        let nonTostringStr = try XCTUnwrap(L.tostring(-1, convert: true))
        XCTAssertTrue(nonTostringStr.hasPrefix("LuaSwift_Type_NoTostringStruct: ")) // The default behaviour of tostring for a named userdata

        struct CustomStruct: CustomStringConvertible {
            var description: String {
                return "woop"
            }
        }
        L.register(Metatable(for: CustomStruct.self, tostring: .synthesize))
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
        L.register(Metatable(for: Foo.self, call: .closure { L in
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
            L.register(Metatable(for: Foo.self, call: .closure { L in
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

    func test_toany() {
        // Things not covered by any of the other pushany tests

        XCTAssertNil(L.toany(1))

        L.pushnil()
        XCTAssertNil(L.toany(1))
        L.pop()

        try! L.dostring("function foo() end")
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
        lua_pushlightuserdata(L, m)
        XCTAssertEqual(L.toany(1) as? UnsafeRawPointer, UnsafeRawPointer(m))
        L.pop()
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
        L.register(Metatable(for: Foo.self))
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
        L.register(Metatable(for: Foo.self, fields: [
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
        L.register(Metatable(for: NonHashable.self))
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
        let _ = lua_newuserdata(L, MemoryLayout<Any>.size)
        let bad: Any? = L.touserdata(-1)
        XCTAssertNil(bad)

        // Now give it a metatable, because touserdata bails early if it doesn't have one
        L.newtable()
        lua_setmetatable(L, -2)
        let stillbad: Any? = L.touserdata(-1)
        XCTAssertNil(stillbad)
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
        L.register(Metatable(for: DeinitChecker.self, close: .synthesize))
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
        var ref: LuaValue? = L.ref(any: "hello")
        XCTAssertEqual(ref!.type, .string) // shut up compiler complaining about unused ref
        L.close()
        XCTAssertNil(ref!.internal_get_L())
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
        L.register(Metatable(for: IndexableValue.self,
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
        XCTAssertEqual(Int8(L.tovalue(1, type: Int.self)!), 3)

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
        let intArrayAsDict = [1: 11, 2: 22, 3: 33]
        let stringIntDict = ["aa": 11, "bb": 22, "cc": 33]
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

        XCTAssertEqual(L.tovalue(4, type: Dictionary<AnyHashable, Any>.self) as? Dictionary<Int, Int>, intArrayAsDict)
        XCTAssertEqual(L.tovalue(4, type: Any.self) as? Dictionary<Int, Int>, intArrayAsDict)
        XCTAssertEqual((L.tovalue(4, type: Any.self) as? Dictionary<AnyHashable, Any>)?.luaTableToArray() as? Array<Int>, intArray)
        XCTAssertEqual(L.tovalue(5, type: Dictionary<AnyHashable, Any>.self) as? Dictionary<String, Int>, stringIntDict)
        XCTAssertEqual(L.tovalue(5, type: Any.self) as? Dictionary<String, Int>, stringIntDict)


        let tableKeyDict = L.tovalue(6, type: Dictionary<[String], Int>.self)
        XCTAssertEqual(tableKeyDict, stringArrayIntDict)

        // Yes this really is a type that has a separate code path - a Dictionary value with a AnyHashable constraint
        let theElderValue = L.tovalue(7, type: Dictionary<Dictionary<String, Dictionary<Int, Int>>, Int>.self)
        XCTAssertEqual(theElderValue, whatEvenIsThis)

        // tables _can_ now be returned as AnyHashable - they will always convert to Dictionary<AnyHashable, AnyHashable>.
        let anyHashableDict: AnyHashable = try XCTUnwrap(L.tovalue(5))
        XCTAssertEqual(anyHashableDict as? [String: Int], stringIntDict)
        XCTAssertEqual((L.tovalue(4, type: AnyHashable.self) as? Dictionary<AnyHashable, AnyHashable>)?.luaTableToArray() as? Array<Int>, intArray)
    }

    // There are 2 basic Any pathways to worry about, which are tovalue<Any> and tovalue<AnyHashable>.
    // Then there are LuaTableRef.doResolveArray and LuaTableRef.doResolveDict which necessarily don't use tovalue,
    // meaning Array<Any>, Array<AnyHashable>, Dictionary<AnyHashable, Any> and Dictionary<AnyHashable, AnyHashable>
    // all need testing too. And for each of *those*, we need to test with string, table and something-that's-neither
    // datatypes.

    func test_tovalue_any_int() {
        L.push(123)
        let anyVal: Any? = L.tovalue(1)
        XCTAssertNotNil(anyVal as? Int)
        let anyHashable: AnyHashable? = L.tovalue(1)
        XCTAssertNotNil(anyHashable as? Int)
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
        XCTAssertEqual(anyDict as? [String: Int], ["abc": 123])

        // Check T=Any does in fact behave the same as T=Dictionary<AnyHashable, Any>
        let anyVal: Any = try XCTUnwrap(L.tovalue(1))
        XCTAssertTrue(type(of: anyVal) == Dictionary<AnyHashable, Any>.self)
        XCTAssertEqual(anyVal as? [String: Int], ["abc": 123])
    }

    func test_tovalue_stringanydict() throws {
        L.newtable()
        L.rawset(-1, key: "abc", value: "def")
        L.rawset(-1, key: "123", value: 456)
        let anyDict: Dictionary<String, Any> = try XCTUnwrap(L.tovalue(1))
        XCTAssertEqual(anyDict["abc"] as? String, "def")
        XCTAssertEqual(anyDict["123"] as? Int, 456)
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
            XCTAssertEqual((err as? LuaLoadError), .parseError(expected))
            XCTAssertEqual((err as CustomStringConvertible).description, "LuaLoadError.parseError(\(expected))")
            XCTAssertEqual(err.localizedDescription, "LuaLoadError.parseError(\(expected))")
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
        lua_newtable(L)
        L.setfuncs([
            "__len": { (L: LuaState!) -> CInt in
                L.push(999)
                return 1
            },
        ])
        lua_setmetatable(L, -2)

        class Foo {}
        L.register(Metatable(for: Foo.self,
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
        L.push(cfn as NSNumber) // 3 - CFNumber as NSNumber (Pushable)
        L.push(cfn_pushable) // 4 - CFNumber as Pushable
        L.push(any: cfn) // 5 - CFNumber as Any
        L.push(nd) // 6 - integer-representable NSNumber from a double
        L.push(ni) // 7 - non-integer-representable NSNumber

        XCTAssertTrue(L.isinteger(1))
        XCTAssertTrue(L.isinteger(6)) // NSNumber does not track the original type, ie that nd was a Double
        XCTAssertFalse(L.isinteger(7))

        XCTAssertEqual(L.toint(1), 1234)
        XCTAssertEqual(L.toint(2), 1234)
        XCTAssertEqual(L.tonumber(3), 1234.5678)
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
        L.register(Metatable(for: ErrStruct.self))
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

        let dict: [AnyHashable: Any] = [1: 111, 2: 222, 3: 333]
        XCTAssertEqual(dict.luaTableToArray() as? [Int], [111, 222, 333])
        XCTAssertEqual((dict as! [AnyHashable: AnyHashable]).luaTableToArray() as? [Int], [111, 222, 333])

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

        // This should succeed because AnyHashable type-erases numbers so 2.0 should be treated just like 2
        let sneakyDouble: [AnyHashable: Any] = [1: 111, 2.0: 222, 3: 333]
        XCTAssertEqual(sneakyDouble.luaTableToArray() as? [Int], [111, 222, 333])
        XCTAssertEqual((sneakyDouble as! [AnyHashable: AnyHashable]).luaTableToArray() as? [Int], [111, 222, 333])

        let sneakyFrac: [AnyHashable: Any] = [1: 111, 2: 222, 2.5: "wat", 3: 333]
        XCTAssertNil((sneakyFrac as! [AnyHashable: AnyHashable]).luaTableToArray())
    }
}
