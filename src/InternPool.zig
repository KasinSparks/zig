//! All interned objects have both a value and a type.
//! This data structure is self-contained, with the following exceptions:
//! * type_struct via Module.Struct.Index
//! * type_opaque via Module.Namespace.Index and Module.Decl.Index

/// Maps `Key` to `Index`. `Key` objects are not stored anywhere; they are
/// constructed lazily.
map: std.AutoArrayHashMapUnmanaged(void, void) = .{},
items: std.MultiArrayList(Item) = .{},
extra: std.ArrayListUnmanaged(u32) = .{},
/// On 32-bit systems, this array is ignored and extra is used for everything.
/// On 64-bit systems, this array is used for big integers and associated metadata.
/// Use the helper methods instead of accessing this directly in order to not
/// violate the above mechanism.
limbs: std.ArrayListUnmanaged(u64) = .{},
/// In order to store references to strings in fewer bytes, we copy all
/// string bytes into here. String bytes can be null. It is up to whomever
/// is referencing the data here whether they want to store both index and length,
/// thus allowing null bytes, or store only index, and use null-termination. The
/// `string_bytes` array is agnostic to either usage.
string_bytes: std.ArrayListUnmanaged(u8) = .{},

/// Struct objects are stored in this data structure because:
/// * They contain pointers such as the field maps.
/// * They need to be mutated after creation.
allocated_structs: std.SegmentedList(Module.Struct, 0) = .{},
/// When a Struct object is freed from `allocated_structs`, it is pushed into this stack.
structs_free_list: std.ArrayListUnmanaged(Module.Struct.Index) = .{},

/// Union objects are stored in this data structure because:
/// * They contain pointers such as the field maps.
/// * They need to be mutated after creation.
allocated_unions: std.SegmentedList(Module.Union, 0) = .{},
/// When a Union object is freed from `allocated_unions`, it is pushed into this stack.
unions_free_list: std.ArrayListUnmanaged(Module.Union.Index) = .{},

/// Fn objects are stored in this data structure because:
/// * They need to be mutated after creation.
allocated_funcs: std.SegmentedList(Module.Fn, 0) = .{},
/// When a Fn object is freed from `allocated_funcs`, it is pushed into this stack.
funcs_free_list: std.ArrayListUnmanaged(Module.Fn.Index) = .{},

/// InferredErrorSet objects are stored in this data structure because:
/// * They contain pointers such as the errors map and the set of other inferred error sets.
/// * They need to be mutated after creation.
allocated_inferred_error_sets: std.SegmentedList(Module.Fn.InferredErrorSet, 0) = .{},
/// When a Struct object is freed from `allocated_inferred_error_sets`, it is
/// pushed into this stack.
inferred_error_sets_free_list: std.ArrayListUnmanaged(Module.Fn.InferredErrorSet.Index) = .{},

/// Some types such as enums, structs, and unions need to store mappings from field names
/// to field index, or value to field index. In such cases, they will store the underlying
/// field names and values directly, relying on one of these maps, stored separately,
/// to provide lookup.
maps: std.ArrayListUnmanaged(std.AutoArrayHashMapUnmanaged(void, void)) = .{},

/// Used for finding the index inside `string_bytes`.
string_table: std.HashMapUnmanaged(
    u32,
    void,
    std.hash_map.StringIndexContext,
    std.hash_map.default_max_load_percentage,
) = .{},

const builtin = @import("builtin");
const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const BigIntConst = std.math.big.int.Const;
const BigIntMutable = std.math.big.int.Mutable;
const Limb = std.math.big.Limb;

const InternPool = @This();
const Module = @import("Module.zig");
const Sema = @import("Sema.zig");

const KeyAdapter = struct {
    intern_pool: *const InternPool,

    pub fn eql(ctx: @This(), a: Key, b_void: void, b_map_index: usize) bool {
        _ = b_void;
        return ctx.intern_pool.indexToKey(@intToEnum(Index, b_map_index)).eql(a, ctx.intern_pool);
    }

    pub fn hash(ctx: @This(), a: Key) u32 {
        return a.hash32(ctx.intern_pool);
    }
};

/// An index into `maps` which might be `none`.
pub const OptionalMapIndex = enum(u32) {
    none = std.math.maxInt(u32),
    _,

    pub fn unwrap(oi: OptionalMapIndex) ?MapIndex {
        if (oi == .none) return null;
        return @intToEnum(MapIndex, @enumToInt(oi));
    }
};

/// An index into `maps`.
pub const MapIndex = enum(u32) {
    _,

    pub fn toOptional(i: MapIndex) OptionalMapIndex {
        return @intToEnum(OptionalMapIndex, @enumToInt(i));
    }
};

pub const RuntimeIndex = enum(u32) {
    zero = 0,
    comptime_field_ptr = std.math.maxInt(u32),
    _,

    pub fn increment(ri: *RuntimeIndex) void {
        ri.* = @intToEnum(RuntimeIndex, @enumToInt(ri.*) + 1);
    }
};

/// An index into `string_bytes`.
pub const String = enum(u32) {
    _,
};

/// An index into `string_bytes`.
pub const NullTerminatedString = enum(u32) {
    _,

    pub fn toString(self: NullTerminatedString) String {
        return @intToEnum(String, @enumToInt(self));
    }

    pub fn toOptional(self: NullTerminatedString) OptionalNullTerminatedString {
        return @intToEnum(OptionalNullTerminatedString, @enumToInt(self));
    }

    const Adapter = struct {
        strings: []const NullTerminatedString,

        pub fn eql(ctx: @This(), a: NullTerminatedString, b_void: void, b_map_index: usize) bool {
            _ = b_void;
            return a == ctx.strings[b_map_index];
        }

        pub fn hash(ctx: @This(), a: NullTerminatedString) u32 {
            _ = ctx;
            return std.hash.uint32(@enumToInt(a));
        }
    };

    /// Compare based on integer value alone, ignoring the string contents.
    pub fn indexLessThan(ctx: void, a: NullTerminatedString, b: NullTerminatedString) bool {
        _ = ctx;
        return @enumToInt(a) < @enumToInt(b);
    }
};

/// An index into `string_bytes` which might be `none`.
pub const OptionalNullTerminatedString = enum(u32) {
    none = std.math.maxInt(u32),
    _,

    pub fn unwrap(oi: OptionalNullTerminatedString) ?NullTerminatedString {
        if (oi == .none) return null;
        return @intToEnum(NullTerminatedString, @enumToInt(oi));
    }
};

pub const Key = union(enum) {
    int_type: IntType,
    ptr_type: PtrType,
    array_type: ArrayType,
    vector_type: VectorType,
    opt_type: Index,
    /// `anyframe->T`. The payload is the child type, which may be `none` to indicate
    /// `anyframe`.
    anyframe_type: Index,
    error_union_type: ErrorUnionType,
    simple_type: SimpleType,
    /// This represents a struct that has been explicitly declared in source code,
    /// or was created with `@Type`. It is unique and based on a declaration.
    /// It may be a tuple, if declared like this: `struct {A, B, C}`.
    struct_type: StructType,
    /// This is an anonymous struct or tuple type which has no corresponding
    /// declaration. It is used for types that have no `struct` keyword in the
    /// source code, and were not created via `@Type`.
    anon_struct_type: AnonStructType,
    union_type: UnionType,
    opaque_type: OpaqueType,
    enum_type: EnumType,
    func_type: FuncType,
    error_set_type: ErrorSetType,
    inferred_error_set_type: Module.Fn.InferredErrorSet.Index,

    /// Typed `undefined`. This will never be `none`; untyped `undefined` is represented
    /// via `simple_value` and has a named `Index` tag for it.
    undef: Index,
    runtime_value: TypeValue,
    simple_value: SimpleValue,
    variable: Key.Variable,
    extern_func: ExternFunc,
    func: Func,
    int: Key.Int,
    err: Error,
    error_union: ErrorUnion,
    enum_literal: NullTerminatedString,
    /// A specific enum tag, indicated by the integer tag value.
    enum_tag: Key.EnumTag,
    float: Key.Float,
    ptr: Ptr,
    opt: Opt,
    /// An instance of a struct, array, or vector.
    /// Each element/field stored as an `Index`.
    /// In the case of sentinel-terminated arrays, the sentinel value *is* stored,
    /// so the slice length will be one more than the type's array length.
    aggregate: Key.Aggregate,
    /// An instance of a union.
    un: Union,

    /// A declaration with a memoized value.
    memoized_decl: MemoizedDecl,
    /// A comptime function call with a memoized result.
    memoized_call: Key.MemoizedCall,

    pub const TypeValue = struct {
        ty: Index,
        val: Index,
    };

    pub const IntType = std.builtin.Type.Int;

    pub const ErrorUnionType = struct {
        error_set_type: Index,
        payload_type: Index,
    };

    pub const ErrorSetType = struct {
        /// Set of error names, sorted by null terminated string index.
        names: []const NullTerminatedString,
        /// This is ignored by `get` but will always be provided by `indexToKey`.
        names_map: OptionalMapIndex = .none,

        /// Look up field index based on field name.
        pub fn nameIndex(self: ErrorSetType, ip: *const InternPool, name: NullTerminatedString) ?u32 {
            const map = &ip.maps.items[@enumToInt(self.names_map.unwrap().?)];
            const adapter: NullTerminatedString.Adapter = .{ .strings = self.names };
            const field_index = map.getIndexAdapted(name, adapter) orelse return null;
            return @intCast(u32, field_index);
        }
    };

    pub const PtrType = struct {
        elem_type: Index,
        sentinel: Index = .none,
        /// `none` indicates the ABI alignment of the pointee_type. In this
        /// case, this field *must* be set to `none`, otherwise the
        /// `InternPool` equality and hashing functions will return incorrect
        /// results.
        alignment: Alignment = .none,
        /// If this is non-zero it means the pointer points to a sub-byte
        /// range of data, which is backed by a "host integer" with this
        /// number of bytes.
        /// When host_size=pointee_abi_size and bit_offset=0, this must be
        /// represented with host_size=0 instead.
        host_size: u16 = 0,
        bit_offset: u16 = 0,
        vector_index: VectorIndex = .none,
        size: std.builtin.Type.Pointer.Size = .One,
        is_const: bool = false,
        is_volatile: bool = false,
        is_allowzero: bool = false,
        /// See src/target.zig defaultAddressSpace function for how to obtain
        /// an appropriate value for this field.
        address_space: std.builtin.AddressSpace = .generic,

        pub const VectorIndex = enum(u16) {
            none = std.math.maxInt(u16),
            runtime = std.math.maxInt(u16) - 1,
            _,
        };
    };

    pub const ArrayType = struct {
        len: u64,
        child: Index,
        sentinel: Index = .none,
    };

    pub const VectorType = struct {
        len: u32,
        child: Index,
    };

    pub const OpaqueType = struct {
        /// The Decl that corresponds to the opaque itself.
        decl: Module.Decl.Index,
        /// Represents the declarations inside this opaque.
        namespace: Module.Namespace.Index,
    };

    pub const StructType = struct {
        /// The `none` tag is used to represent a struct with no fields.
        index: Module.Struct.OptionalIndex,
        /// May be `none` if the struct has no declarations.
        namespace: Module.Namespace.OptionalIndex,
    };

    pub const AnonStructType = struct {
        types: []const Index,
        /// This may be empty, indicating this is a tuple.
        names: []const NullTerminatedString,
        /// These elements may be `none`, indicating runtime-known.
        values: []const Index,

        pub fn isTuple(self: AnonStructType) bool {
            return self.names.len == 0;
        }
    };

    pub const UnionType = struct {
        index: Module.Union.Index,
        runtime_tag: RuntimeTag,

        pub const RuntimeTag = enum { none, safety, tagged };

        pub fn hasTag(self: UnionType) bool {
            return switch (self.runtime_tag) {
                .none => false,
                .tagged, .safety => true,
            };
        }
    };

    pub const EnumType = struct {
        /// The Decl that corresponds to the enum itself.
        decl: Module.Decl.Index,
        /// Represents the declarations inside this enum.
        namespace: Module.Namespace.OptionalIndex,
        /// An integer type which is used for the numerical value of the enum.
        /// This field is present regardless of whether the enum has an
        /// explicitly provided tag type or auto-numbered.
        tag_ty: Index,
        /// Set of field names in declaration order.
        names: []const NullTerminatedString,
        /// Maps integer tag value to field index.
        /// Entries are in declaration order, same as `fields`.
        /// If this is empty, it means the enum tags are auto-numbered.
        values: []const Index,
        tag_mode: TagMode,
        /// This is ignored by `get` but will always be provided by `indexToKey`.
        names_map: OptionalMapIndex = .none,
        /// This is ignored by `get` but will be provided by `indexToKey` when
        /// a value map exists.
        values_map: OptionalMapIndex = .none,

        pub const TagMode = enum {
            /// The integer tag type was auto-numbered by zig.
            auto,
            /// The integer tag type was provided by the enum declaration, and the enum
            /// is exhaustive.
            explicit,
            /// The integer tag type was provided by the enum declaration, and the enum
            /// is non-exhaustive.
            nonexhaustive,
        };

        /// Look up field index based on field name.
        pub fn nameIndex(self: EnumType, ip: *const InternPool, name: NullTerminatedString) ?u32 {
            const map = &ip.maps.items[@enumToInt(self.names_map.unwrap().?)];
            const adapter: NullTerminatedString.Adapter = .{ .strings = self.names };
            const field_index = map.getIndexAdapted(name, adapter) orelse return null;
            return @intCast(u32, field_index);
        }

        /// Look up field index based on tag value.
        /// Asserts that `values_map` is not `none`.
        /// This function returns `null` when `tag_val` does not have the
        /// integer tag type of the enum.
        pub fn tagValueIndex(self: EnumType, ip: *const InternPool, tag_val: Index) ?u32 {
            assert(tag_val != .none);
            if (self.values_map.unwrap()) |values_map| {
                const map = &ip.maps.items[@enumToInt(values_map)];
                const adapter: Index.Adapter = .{ .indexes = self.values };
                const field_index = map.getIndexAdapted(tag_val, adapter) orelse return null;
                return @intCast(u32, field_index);
            }
            // Auto-numbered enum. Convert `tag_val` to field index.
            switch (ip.indexToKey(tag_val).int.storage) {
                .u64 => |x| {
                    if (x >= self.names.len) return null;
                    return @intCast(u32, x);
                },
                .i64, .big_int => return null, // out of range
                .lazy_align, .lazy_size => unreachable,
            }
        }
    };

    pub const IncompleteEnumType = struct {
        /// Same as corresponding `EnumType` field.
        decl: Module.Decl.Index,
        /// Same as corresponding `EnumType` field.
        namespace: Module.Namespace.OptionalIndex,
        /// The field names and field values are not known yet, but
        /// the number of fields must be known ahead of time.
        fields_len: u32,
        /// This information is needed so that the size does not change
        /// later when populating field values.
        has_values: bool,
        /// Same as corresponding `EnumType` field.
        tag_mode: EnumType.TagMode,
        /// This may be updated via `setTagType` later.
        tag_ty: Index = .none,

        pub fn toEnumType(self: @This()) EnumType {
            return .{
                .decl = self.decl,
                .namespace = self.namespace,
                .tag_ty = self.tag_ty,
                .tag_mode = self.tag_mode,
                .names = &.{},
                .values = &.{},
            };
        }

        /// Only the decl is used for hashing and equality, so we can construct
        /// this minimal key for use with `map`.
        pub fn toKey(self: @This()) Key {
            return .{ .enum_type = self.toEnumType() };
        }
    };

    pub const FuncType = struct {
        param_types: []Index,
        return_type: Index,
        /// Tells whether a parameter is comptime. See `paramIsComptime` helper
        /// method for accessing this.
        comptime_bits: u32,
        /// Tells whether a parameter is noalias. See `paramIsNoalias` helper
        /// method for accessing this.
        noalias_bits: u32,
        /// `none` indicates the function has the default alignment for
        /// function code on the target. In this case, this field *must* be set
        /// to `none`, otherwise the `InternPool` equality and hashing
        /// functions will return incorrect results.
        alignment: Alignment,
        cc: std.builtin.CallingConvention,
        is_var_args: bool,
        is_generic: bool,
        is_noinline: bool,
        align_is_generic: bool,
        cc_is_generic: bool,
        section_is_generic: bool,
        addrspace_is_generic: bool,

        pub fn paramIsComptime(self: @This(), i: u5) bool {
            assert(i < self.param_types.len);
            return @truncate(u1, self.comptime_bits >> i) != 0;
        }

        pub fn paramIsNoalias(self: @This(), i: u5) bool {
            assert(i < self.param_types.len);
            return @truncate(u1, self.noalias_bits >> i) != 0;
        }
    };

    pub const Variable = struct {
        ty: Index,
        init: Index,
        decl: Module.Decl.Index,
        lib_name: OptionalNullTerminatedString = .none,
        is_extern: bool = false,
        is_const: bool = false,
        is_threadlocal: bool = false,
        is_weak_linkage: bool = false,
    };

    pub const ExternFunc = struct {
        ty: Index,
        /// The Decl that corresponds to the function itself.
        decl: Module.Decl.Index,
        /// Library name if specified.
        /// For example `extern "c" fn write(...) usize` would have 'c' as library name.
        /// Index into the string table bytes.
        lib_name: OptionalNullTerminatedString,
    };

    pub const Func = struct {
        ty: Index,
        index: Module.Fn.Index,
    };

    pub const Int = struct {
        ty: Index,
        storage: Storage,

        pub const Storage = union(enum) {
            u64: u64,
            i64: i64,
            big_int: BigIntConst,
            lazy_align: Index,
            lazy_size: Index,

            /// Big enough to fit any non-BigInt value
            pub const BigIntSpace = struct {
                /// The +1 is headroom so that operations such as incrementing once
                /// or decrementing once are possible without using an allocator.
                limbs: [(@sizeOf(u64) / @sizeOf(std.math.big.Limb)) + 1]std.math.big.Limb,
            };

            pub fn toBigInt(storage: Storage, space: *BigIntSpace) BigIntConst {
                return switch (storage) {
                    .big_int => |x| x,
                    inline .u64, .i64 => |x| BigIntMutable.init(&space.limbs, x).toConst(),
                    .lazy_align, .lazy_size => unreachable,
                };
            }
        };
    };

    pub const Error = struct {
        ty: Index,
        name: NullTerminatedString,
    };

    pub const ErrorUnion = struct {
        ty: Index,
        val: Value,

        pub const Value = union(enum) {
            err_name: NullTerminatedString,
            payload: Index,
        };
    };

    pub const EnumTag = struct {
        /// The enum type.
        ty: Index,
        /// The integer tag value which has the integer tag type of the enum.
        int: Index,
    };

    pub const Float = struct {
        ty: Index,
        /// The storage used must match the size of the float type being represented.
        storage: Storage,

        pub const Storage = union(enum) {
            f16: f16,
            f32: f32,
            f64: f64,
            f80: f80,
            f128: f128,
        };
    };

    pub const Ptr = struct {
        /// This is the pointer type, not the element type.
        ty: Index,
        /// The value of the address that the pointer points to.
        addr: Addr,
        /// This could be `none` if size is not a slice.
        len: Index = .none,

        pub const Addr = union(enum) {
            decl: Module.Decl.Index,
            mut_decl: MutDecl,
            comptime_field: Index,
            int: Index,
            eu_payload: Index,
            opt_payload: Index,
            elem: BaseIndex,
            field: BaseIndex,

            pub const MutDecl = struct {
                decl: Module.Decl.Index,
                runtime_index: RuntimeIndex,
            };
            pub const BaseIndex = struct {
                base: Index,
                index: u64,
            };
        };
    };

    /// `null` is represented by the `val` field being `none`.
    pub const Opt = struct {
        /// This is the optional type; not the payload type.
        ty: Index,
        /// This could be `none`, indicating the optional is `null`.
        val: Index,
    };

    pub const Union = struct {
        /// This is the union type; not the field type.
        ty: Index,
        /// Indicates the active field.
        tag: Index,
        /// The value of the active field.
        val: Index,
    };

    pub const Aggregate = struct {
        ty: Index,
        storage: Storage,

        pub const Storage = union(enum) {
            bytes: []const u8,
            elems: []const Index,
            repeated_elem: Index,

            pub fn values(self: *const Storage) []const Index {
                return switch (self.*) {
                    .bytes => &.{},
                    .elems => |elems| elems,
                    .repeated_elem => |*elem| @as(*const [1]Index, elem),
                };
            }
        };
    };

    pub const MemoizedDecl = struct {
        val: Index,
        decl: Module.Decl.Index,
    };

    pub const MemoizedCall = struct {
        func: Module.Fn.Index,
        arg_values: []const Index,
        result: Index,
    };

    pub fn hash32(key: Key, ip: *const InternPool) u32 {
        return @truncate(u32, key.hash64(ip));
    }

    pub fn hash64(key: Key, ip: *const InternPool) u64 {
        var hasher = std.hash.Wyhash.init(0);
        key.hashWithHasher(&hasher, ip);
        return hasher.final();
    }

    pub fn hashWithHasher(key: Key, hasher: *std.hash.Wyhash, ip: *const InternPool) void {
        const KeyTag = @typeInfo(Key).Union.tag_type.?;
        std.hash.autoHash(hasher, @as(KeyTag, key));
        switch (key) {
            inline .int_type,
            .ptr_type,
            .array_type,
            .vector_type,
            .opt_type,
            .anyframe_type,
            .error_union_type,
            .simple_type,
            .simple_value,
            .opt,
            .struct_type,
            .union_type,
            .un,
            .undef,
            .err,
            .error_union,
            .enum_literal,
            .enum_tag,
            .inferred_error_set_type,
            => |info| std.hash.autoHash(hasher, info),

            .runtime_value => |runtime_value| std.hash.autoHash(hasher, runtime_value.val),
            .opaque_type => |opaque_type| std.hash.autoHash(hasher, opaque_type.decl),
            .enum_type => |enum_type| std.hash.autoHash(hasher, enum_type.decl),

            .variable => |variable| std.hash.autoHash(hasher, variable.decl),
            .extern_func => |extern_func| {
                std.hash.autoHash(hasher, extern_func.ty);
                std.hash.autoHash(hasher, extern_func.decl);
            },
            .func => |func| {
                std.hash.autoHash(hasher, func.ty);
                std.hash.autoHash(hasher, func.index);
            },

            .int => |int| {
                // Canonicalize all integers by converting them to BigIntConst.
                switch (int.storage) {
                    .u64, .i64, .big_int => {
                        var buffer: Key.Int.Storage.BigIntSpace = undefined;
                        const big_int = int.storage.toBigInt(&buffer);

                        std.hash.autoHash(hasher, int.ty);
                        std.hash.autoHash(hasher, big_int.positive);
                        for (big_int.limbs) |limb| std.hash.autoHash(hasher, limb);
                    },
                    .lazy_align, .lazy_size => |lazy_ty| {
                        std.hash.autoHash(
                            hasher,
                            @as(@typeInfo(Key.Int.Storage).Union.tag_type.?, int.storage),
                        );
                        std.hash.autoHash(hasher, lazy_ty);
                    },
                }
            },

            .float => |float| {
                std.hash.autoHash(hasher, float.ty);
                switch (float.storage) {
                    inline else => |val| std.hash.autoHash(
                        hasher,
                        @bitCast(std.meta.Int(.unsigned, @bitSizeOf(@TypeOf(val))), val),
                    ),
                }
            },

            .ptr => |ptr| {
                std.hash.autoHash(hasher, ptr.ty);
                std.hash.autoHash(hasher, ptr.len);
                // Int-to-ptr pointers are hashed separately than decl-referencing pointers.
                // This is sound due to pointer provenance rules.
                std.hash.autoHash(hasher, @as(@typeInfo(Key.Ptr.Addr).Union.tag_type.?, ptr.addr));
                switch (ptr.addr) {
                    .decl => |decl| std.hash.autoHash(hasher, decl),
                    .mut_decl => |mut_decl| std.hash.autoHash(hasher, mut_decl),
                    .int => |int| std.hash.autoHash(hasher, int),
                    .eu_payload => |eu_payload| std.hash.autoHash(hasher, eu_payload),
                    .opt_payload => |opt_payload| std.hash.autoHash(hasher, opt_payload),
                    .comptime_field => |comptime_field| std.hash.autoHash(hasher, comptime_field),
                    .elem => |elem| std.hash.autoHash(hasher, elem),
                    .field => |field| std.hash.autoHash(hasher, field),
                }
            },

            .aggregate => |aggregate| {
                std.hash.autoHash(hasher, aggregate.ty);
                const len = ip.aggregateTypeLen(aggregate.ty);
                const child = switch (ip.indexToKey(aggregate.ty)) {
                    .array_type => |array_type| array_type.child,
                    .vector_type => |vector_type| vector_type.child,
                    .anon_struct_type, .struct_type => .none,
                    else => unreachable,
                };

                if (child == .u8_type) {
                    switch (aggregate.storage) {
                        .bytes => |bytes| for (bytes[0..@intCast(usize, len)]) |byte| {
                            std.hash.autoHash(hasher, KeyTag.int);
                            std.hash.autoHash(hasher, byte);
                        },
                        .elems => |elems| for (elems[0..@intCast(usize, len)]) |elem| {
                            const elem_key = ip.indexToKey(elem);
                            std.hash.autoHash(hasher, @as(KeyTag, elem_key));
                            switch (elem_key) {
                                .undef => {},
                                .int => |int| std.hash.autoHash(
                                    hasher,
                                    @intCast(u8, int.storage.u64),
                                ),
                                else => unreachable,
                            }
                        },
                        .repeated_elem => |elem| {
                            const elem_key = ip.indexToKey(elem);
                            var remaining = len;
                            while (remaining > 0) : (remaining -= 1) {
                                std.hash.autoHash(hasher, @as(KeyTag, elem_key));
                                switch (elem_key) {
                                    .undef => {},
                                    .int => |int| std.hash.autoHash(
                                        hasher,
                                        @intCast(u8, int.storage.u64),
                                    ),
                                    else => unreachable,
                                }
                            }
                        },
                    }
                    return;
                }

                switch (aggregate.storage) {
                    .bytes => unreachable,
                    .elems => |elems| for (elems[0..@intCast(usize, len)]) |elem|
                        std.hash.autoHash(hasher, elem),
                    .repeated_elem => |elem| {
                        var remaining = len;
                        while (remaining > 0) : (remaining -= 1) std.hash.autoHash(hasher, elem);
                    },
                }
            },

            .error_set_type => |error_set_type| {
                for (error_set_type.names) |elem| std.hash.autoHash(hasher, elem);
            },

            .anon_struct_type => |anon_struct_type| {
                for (anon_struct_type.types) |elem| std.hash.autoHash(hasher, elem);
                for (anon_struct_type.values) |elem| std.hash.autoHash(hasher, elem);
                for (anon_struct_type.names) |elem| std.hash.autoHash(hasher, elem);
            },

            .func_type => |func_type| {
                for (func_type.param_types) |param_type| std.hash.autoHash(hasher, param_type);
                std.hash.autoHash(hasher, func_type.return_type);
                std.hash.autoHash(hasher, func_type.comptime_bits);
                std.hash.autoHash(hasher, func_type.noalias_bits);
                std.hash.autoHash(hasher, func_type.alignment);
                std.hash.autoHash(hasher, func_type.cc);
                std.hash.autoHash(hasher, func_type.is_var_args);
                std.hash.autoHash(hasher, func_type.is_generic);
                std.hash.autoHash(hasher, func_type.is_noinline);
            },

            .memoized_decl => |memoized_decl| std.hash.autoHash(hasher, memoized_decl.val),

            .memoized_call => |memoized_call| {
                std.hash.autoHash(hasher, memoized_call.func);
                for (memoized_call.arg_values) |arg| std.hash.autoHash(hasher, arg);
            },
        }
    }

    pub fn eql(a: Key, b: Key, ip: *const InternPool) bool {
        const KeyTag = @typeInfo(Key).Union.tag_type.?;
        const a_tag: KeyTag = a;
        const b_tag: KeyTag = b;
        if (a_tag != b_tag) return false;
        switch (a) {
            .int_type => |a_info| {
                const b_info = b.int_type;
                return std.meta.eql(a_info, b_info);
            },
            .ptr_type => |a_info| {
                const b_info = b.ptr_type;
                return std.meta.eql(a_info, b_info);
            },
            .array_type => |a_info| {
                const b_info = b.array_type;
                return std.meta.eql(a_info, b_info);
            },
            .vector_type => |a_info| {
                const b_info = b.vector_type;
                return std.meta.eql(a_info, b_info);
            },
            .opt_type => |a_info| {
                const b_info = b.opt_type;
                return a_info == b_info;
            },
            .anyframe_type => |a_info| {
                const b_info = b.anyframe_type;
                return a_info == b_info;
            },
            .error_union_type => |a_info| {
                const b_info = b.error_union_type;
                return std.meta.eql(a_info, b_info);
            },
            .simple_type => |a_info| {
                const b_info = b.simple_type;
                return a_info == b_info;
            },
            .simple_value => |a_info| {
                const b_info = b.simple_value;
                return a_info == b_info;
            },
            .undef => |a_info| {
                const b_info = b.undef;
                return a_info == b_info;
            },
            .runtime_value => |a_info| {
                const b_info = b.runtime_value;
                return a_info.val == b_info.val;
            },
            .opt => |a_info| {
                const b_info = b.opt;
                return std.meta.eql(a_info, b_info);
            },
            .struct_type => |a_info| {
                const b_info = b.struct_type;
                return std.meta.eql(a_info, b_info);
            },
            .union_type => |a_info| {
                const b_info = b.union_type;
                return std.meta.eql(a_info, b_info);
            },
            .un => |a_info| {
                const b_info = b.un;
                return std.meta.eql(a_info, b_info);
            },
            .err => |a_info| {
                const b_info = b.err;
                return std.meta.eql(a_info, b_info);
            },
            .error_union => |a_info| {
                const b_info = b.error_union;
                return std.meta.eql(a_info, b_info);
            },
            .enum_literal => |a_info| {
                const b_info = b.enum_literal;
                return a_info == b_info;
            },
            .enum_tag => |a_info| {
                const b_info = b.enum_tag;
                return std.meta.eql(a_info, b_info);
            },

            .variable => |a_info| {
                const b_info = b.variable;
                return a_info.decl == b_info.decl;
            },
            .extern_func => |a_info| {
                const b_info = b.extern_func;
                return a_info.ty == b_info.ty and a_info.decl == b_info.decl;
            },
            .func => |a_info| {
                const b_info = b.func;
                return a_info.ty == b_info.ty and a_info.index == b_info.index;
            },

            .ptr => |a_info| {
                const b_info = b.ptr;
                if (a_info.ty != b_info.ty or a_info.len != b_info.len) return false;

                const AddrTag = @typeInfo(Key.Ptr.Addr).Union.tag_type.?;
                if (@as(AddrTag, a_info.addr) != @as(AddrTag, b_info.addr)) return false;

                return switch (a_info.addr) {
                    .decl => |a_decl| a_decl == b_info.addr.decl,
                    .mut_decl => |a_mut_decl| std.meta.eql(a_mut_decl, b_info.addr.mut_decl),
                    .int => |a_int| a_int == b_info.addr.int,
                    .eu_payload => |a_eu_payload| a_eu_payload == b_info.addr.eu_payload,
                    .opt_payload => |a_opt_payload| a_opt_payload == b_info.addr.opt_payload,
                    .comptime_field => |a_comptime_field| a_comptime_field == b_info.addr.comptime_field,
                    .elem => |a_elem| std.meta.eql(a_elem, b_info.addr.elem),
                    .field => |a_field| std.meta.eql(a_field, b_info.addr.field),
                };
            },

            .int => |a_info| {
                const b_info = b.int;

                if (a_info.ty != b_info.ty)
                    return false;

                return switch (a_info.storage) {
                    .u64 => |aa| switch (b_info.storage) {
                        .u64 => |bb| aa == bb,
                        .i64 => |bb| aa == bb,
                        .big_int => |bb| bb.orderAgainstScalar(aa) == .eq,
                        .lazy_align, .lazy_size => false,
                    },
                    .i64 => |aa| switch (b_info.storage) {
                        .u64 => |bb| aa == bb,
                        .i64 => |bb| aa == bb,
                        .big_int => |bb| bb.orderAgainstScalar(aa) == .eq,
                        .lazy_align, .lazy_size => false,
                    },
                    .big_int => |aa| switch (b_info.storage) {
                        .u64 => |bb| aa.orderAgainstScalar(bb) == .eq,
                        .i64 => |bb| aa.orderAgainstScalar(bb) == .eq,
                        .big_int => |bb| aa.eq(bb),
                        .lazy_align, .lazy_size => false,
                    },
                    .lazy_align => |aa| switch (b_info.storage) {
                        .u64, .i64, .big_int, .lazy_size => false,
                        .lazy_align => |bb| aa == bb,
                    },
                    .lazy_size => |aa| switch (b_info.storage) {
                        .u64, .i64, .big_int, .lazy_align => false,
                        .lazy_size => |bb| aa == bb,
                    },
                };
            },

            .float => |a_info| {
                const b_info = b.float;

                if (a_info.ty != b_info.ty)
                    return false;

                if (a_info.ty == .c_longdouble_type and a_info.storage != .f80) {
                    // These are strange: we'll sometimes represent them as f128, even if the
                    // underlying type is smaller. f80 is an exception: see float_c_longdouble_f80.
                    const a_val = switch (a_info.storage) {
                        inline else => |val| @floatCast(f128, val),
                    };
                    const b_val = switch (b_info.storage) {
                        inline else => |val| @floatCast(f128, val),
                    };
                    return a_val == b_val;
                }

                const StorageTag = @typeInfo(Key.Float.Storage).Union.tag_type.?;
                assert(@as(StorageTag, a_info.storage) == @as(StorageTag, b_info.storage));

                return switch (a_info.storage) {
                    inline else => |val, tag| val == @field(b_info.storage, @tagName(tag)),
                };
            },

            .opaque_type => |a_info| {
                const b_info = b.opaque_type;
                return a_info.decl == b_info.decl;
            },
            .enum_type => |a_info| {
                const b_info = b.enum_type;
                return a_info.decl == b_info.decl;
            },
            .aggregate => |a_info| {
                const b_info = b.aggregate;
                if (a_info.ty != b_info.ty) return false;

                const len = ip.aggregateTypeLen(a_info.ty);
                const StorageTag = @typeInfo(Key.Aggregate.Storage).Union.tag_type.?;
                if (@as(StorageTag, a_info.storage) != @as(StorageTag, b_info.storage)) {
                    for (0..@intCast(usize, len)) |elem_index| {
                        const a_elem = switch (a_info.storage) {
                            .bytes => |bytes| ip.getIfExists(.{ .int = .{
                                .ty = .u8_type,
                                .storage = .{ .u64 = bytes[elem_index] },
                            } }) orelse return false,
                            .elems => |elems| elems[elem_index],
                            .repeated_elem => |elem| elem,
                        };
                        const b_elem = switch (b_info.storage) {
                            .bytes => |bytes| ip.getIfExists(.{ .int = .{
                                .ty = .u8_type,
                                .storage = .{ .u64 = bytes[elem_index] },
                            } }) orelse return false,
                            .elems => |elems| elems[elem_index],
                            .repeated_elem => |elem| elem,
                        };
                        if (a_elem != b_elem) return false;
                    }
                    return true;
                }

                switch (a_info.storage) {
                    .bytes => |a_bytes| {
                        const b_bytes = b_info.storage.bytes;
                        return std.mem.eql(
                            u8,
                            a_bytes[0..@intCast(usize, len)],
                            b_bytes[0..@intCast(usize, len)],
                        );
                    },
                    .elems => |a_elems| {
                        const b_elems = b_info.storage.elems;
                        return std.mem.eql(
                            Index,
                            a_elems[0..@intCast(usize, len)],
                            b_elems[0..@intCast(usize, len)],
                        );
                    },
                    .repeated_elem => |a_elem| {
                        const b_elem = b_info.storage.repeated_elem;
                        return a_elem == b_elem;
                    },
                }
            },
            .anon_struct_type => |a_info| {
                const b_info = b.anon_struct_type;
                return std.mem.eql(Index, a_info.types, b_info.types) and
                    std.mem.eql(Index, a_info.values, b_info.values) and
                    std.mem.eql(NullTerminatedString, a_info.names, b_info.names);
            },
            .error_set_type => |a_info| {
                const b_info = b.error_set_type;
                return std.mem.eql(NullTerminatedString, a_info.names, b_info.names);
            },
            .inferred_error_set_type => |a_info| {
                const b_info = b.inferred_error_set_type;
                return a_info == b_info;
            },

            .func_type => |a_info| {
                const b_info = b.func_type;

                return std.mem.eql(Index, a_info.param_types, b_info.param_types) and
                    a_info.return_type == b_info.return_type and
                    a_info.comptime_bits == b_info.comptime_bits and
                    a_info.noalias_bits == b_info.noalias_bits and
                    a_info.alignment == b_info.alignment and
                    a_info.cc == b_info.cc and
                    a_info.is_var_args == b_info.is_var_args and
                    a_info.is_generic == b_info.is_generic and
                    a_info.is_noinline == b_info.is_noinline;
            },

            .memoized_decl => |a_info| {
                const b_info = b.memoized_decl;
                return a_info.val == b_info.val;
            },

            .memoized_call => |a_info| {
                const b_info = b.memoized_call;
                return a_info.func == b_info.func and
                    std.mem.eql(Index, a_info.arg_values, b_info.arg_values);
            },
        }
    }

    pub fn typeOf(key: Key) Index {
        return switch (key) {
            .int_type,
            .ptr_type,
            .array_type,
            .vector_type,
            .opt_type,
            .anyframe_type,
            .error_union_type,
            .error_set_type,
            .inferred_error_set_type,
            .simple_type,
            .struct_type,
            .union_type,
            .opaque_type,
            .enum_type,
            .anon_struct_type,
            .func_type,
            => .type_type,

            inline .runtime_value,
            .ptr,
            .int,
            .float,
            .opt,
            .variable,
            .extern_func,
            .func,
            .err,
            .error_union,
            .enum_tag,
            .aggregate,
            .un,
            => |x| x.ty,

            .enum_literal => .enum_literal_type,

            .undef => |x| x,

            .simple_value => |s| switch (s) {
                .undefined => .undefined_type,
                .void => .void_type,
                .null => .null_type,
                .false, .true => .bool_type,
                .empty_struct => .empty_struct_type,
                .@"unreachable" => .noreturn_type,
                .generic_poison => .generic_poison_type,
            },

            .memoized_decl,
            .memoized_call,
            => unreachable,
        };
    }
};

pub const Item = struct {
    tag: Tag,
    /// The doc comments on the respective Tag explain how to interpret this.
    data: u32,
};

/// Represents an index into `map`. It represents the canonical index
/// of a `Value` within this `InternPool`. The values are typed.
/// Two values which have the same type can be equality compared simply
/// by checking if their indexes are equal, provided they are both in
/// the same `InternPool`.
/// When adding a tag to this enum, consider adding a corresponding entry to
/// `primitives` in AstGen.zig.
pub const Index = enum(u32) {
    pub const first_type: Index = .u1_type;
    pub const last_type: Index = .empty_struct_type;
    pub const first_value: Index = .undef;
    pub const last_value: Index = .empty_struct;

    u1_type,
    u8_type,
    i8_type,
    u16_type,
    i16_type,
    u29_type,
    u32_type,
    i32_type,
    u64_type,
    i64_type,
    u80_type,
    u128_type,
    i128_type,
    usize_type,
    isize_type,
    c_char_type,
    c_short_type,
    c_ushort_type,
    c_int_type,
    c_uint_type,
    c_long_type,
    c_ulong_type,
    c_longlong_type,
    c_ulonglong_type,
    c_longdouble_type,
    f16_type,
    f32_type,
    f64_type,
    f80_type,
    f128_type,
    anyopaque_type,
    bool_type,
    void_type,
    type_type,
    anyerror_type,
    comptime_int_type,
    comptime_float_type,
    noreturn_type,
    anyframe_type,
    null_type,
    undefined_type,
    enum_literal_type,
    atomic_order_type,
    atomic_rmw_op_type,
    calling_convention_type,
    address_space_type,
    float_mode_type,
    reduce_op_type,
    call_modifier_type,
    prefetch_options_type,
    export_options_type,
    extern_options_type,
    type_info_type,
    manyptr_u8_type,
    manyptr_const_u8_type,
    manyptr_const_u8_sentinel_0_type,
    single_const_pointer_to_comptime_int_type,
    slice_const_u8_type,
    slice_const_u8_sentinel_0_type,
    anyerror_void_error_union_type,
    generic_poison_type,
    /// `@TypeOf(.{})`
    empty_struct_type,

    /// `undefined` (untyped)
    undef,
    /// `0` (comptime_int)
    zero,
    /// `0` (usize)
    zero_usize,
    /// `0` (u8)
    zero_u8,
    /// `1` (comptime_int)
    one,
    /// `1` (usize)
    one_usize,
    /// `1` (u8)
    one_u8,
    /// `4` (u8)
    four_u8,
    /// `-1` (comptime_int)
    negative_one,
    /// `std.builtin.CallingConvention.C`
    calling_convention_c,
    /// `std.builtin.CallingConvention.Inline`
    calling_convention_inline,
    /// `{}`
    void_value,
    /// `unreachable` (noreturn type)
    unreachable_value,
    /// `null` (untyped)
    null_value,
    /// `true`
    bool_true,
    /// `false`
    bool_false,
    /// `.{}` (untyped)
    empty_struct,

    /// Used for generic parameters where the type and value
    /// is not known until generic function instantiation.
    generic_poison,

    /// Used by Air/Sema only.
    var_args_param_type = std.math.maxInt(u32) - 1,
    none = std.math.maxInt(u32),

    _,

    pub fn toType(i: Index) @import("type.zig").Type {
        assert(i != .none);
        return .{ .ip_index = i };
    }

    pub fn toValue(i: Index) @import("value.zig").Value {
        assert(i != .none);
        return .{
            .ip_index = i,
            .legacy = undefined,
        };
    }

    /// Used for a map of `Index` values to the index within a list of `Index` values.
    const Adapter = struct {
        indexes: []const Index,

        pub fn eql(ctx: @This(), a: Index, b_void: void, b_map_index: usize) bool {
            _ = b_void;
            return a == ctx.indexes[b_map_index];
        }

        pub fn hash(ctx: @This(), a: Index) u32 {
            _ = ctx;
            return std.hash.uint32(@enumToInt(a));
        }
    };

    /// This function is used in the debugger pretty formatters in tools/ to fetch the
    /// Tag to encoding mapping to facilitate fancy debug printing for this type.
    fn dbHelper(self: *Index, tag_to_encoding_map: *struct {
        const DataIsIndex = struct { data: Index };
        const DataIsExtraIndexOfEnumExplicit = struct {
            const @"data.fields_len" = opaque {};
            data: *EnumExplicit,
            @"trailing.names.len": *@"data.fields_len",
            @"trailing.values.len": *@"data.fields_len",
            trailing: struct {
                names: []NullTerminatedString,
                values: []Index,
            },
        };
        const DataIsExtraIndexOfTypeStructAnon = struct {
            const @"data.fields_len" = opaque {};
            data: *TypeStructAnon,
            @"trailing.types.len": *@"data.fields_len",
            @"trailing.values.len": *@"data.fields_len",
            @"trailing.names.len": *@"data.fields_len",
            trailing: struct {
                types: []Index,
                values: []Index,
                names: []NullTerminatedString,
            },
        };

        type_int_signed: struct { data: u32 },
        type_int_unsigned: struct { data: u32 },
        type_array_big: struct { data: *Array },
        type_array_small: struct { data: *Vector },
        type_vector: struct { data: *Vector },
        type_pointer: struct { data: *Pointer },
        type_slice: DataIsIndex,
        type_optional: DataIsIndex,
        type_anyframe: DataIsIndex,
        type_error_union: struct { data: *Key.ErrorUnionType },
        type_error_set: struct {
            const @"data.names_len" = opaque {};
            data: *ErrorSet,
            @"trailing.names.len": *@"data.names_len",
            trailing: struct { names: []NullTerminatedString },
        },
        type_inferred_error_set: struct { data: Module.Fn.InferredErrorSet.Index },
        type_enum_auto: struct {
            const @"data.fields_len" = opaque {};
            data: *EnumAuto,
            @"trailing.names.len": *@"data.fields_len",
            trailing: struct { names: []NullTerminatedString },
        },
        type_enum_explicit: DataIsExtraIndexOfEnumExplicit,
        type_enum_nonexhaustive: DataIsExtraIndexOfEnumExplicit,
        simple_type: struct { data: SimpleType },
        type_opaque: struct { data: *Key.OpaqueType },
        type_struct: struct { data: Module.Struct.OptionalIndex },
        type_struct_ns: struct { data: Module.Namespace.Index },
        type_struct_anon: DataIsExtraIndexOfTypeStructAnon,
        type_tuple_anon: DataIsExtraIndexOfTypeStructAnon,
        type_union_tagged: struct { data: Module.Union.Index },
        type_union_untagged: struct { data: Module.Union.Index },
        type_union_safety: struct { data: Module.Union.Index },
        type_function: struct {
            const @"data.params_len" = opaque {};
            data: *TypeFunction,
            @"trailing.param_types.len": *@"data.params_len",
            trailing: struct { param_types: []Index },
        },

        undef: DataIsIndex,
        runtime_value: struct { data: *Tag.TypeValue },
        simple_value: struct { data: SimpleValue },
        ptr_decl: struct { data: *PtrDecl },
        ptr_mut_decl: struct { data: *PtrMutDecl },
        ptr_comptime_field: struct { data: *PtrComptimeField },
        ptr_int: struct { data: *PtrBase },
        ptr_eu_payload: struct { data: *PtrBase },
        ptr_opt_payload: struct { data: *PtrBase },
        ptr_elem: struct { data: *PtrBaseIndex },
        ptr_field: struct { data: *PtrBaseIndex },
        ptr_slice: struct { data: *PtrSlice },
        opt_payload: struct { data: *Tag.TypeValue },
        opt_null: DataIsIndex,
        int_u8: struct { data: u8 },
        int_u16: struct { data: u16 },
        int_u32: struct { data: u32 },
        int_i32: struct { data: i32 },
        int_usize: struct { data: u32 },
        int_comptime_int_u32: struct { data: u32 },
        int_comptime_int_i32: struct { data: i32 },
        int_small: struct { data: *IntSmall },
        int_positive: struct { data: u32 },
        int_negative: struct { data: u32 },
        int_lazy_align: struct { data: *IntLazy },
        int_lazy_size: struct { data: *IntLazy },
        error_set_error: struct { data: *Key.Error },
        error_union_error: struct { data: *Key.Error },
        error_union_payload: struct { data: *Tag.TypeValue },
        enum_literal: struct { data: NullTerminatedString },
        enum_tag: struct { data: *Key.EnumTag },
        float_f16: struct { data: f16 },
        float_f32: struct { data: f32 },
        float_f64: struct { data: *Float64 },
        float_f80: struct { data: *Float80 },
        float_f128: struct { data: *Float128 },
        float_c_longdouble_f80: struct { data: *Float80 },
        float_c_longdouble_f128: struct { data: *Float128 },
        float_comptime_float: struct { data: *Float128 },
        variable: struct { data: *Tag.Variable },
        extern_func: struct { data: *Key.ExternFunc },
        func: struct { data: *Key.Func },
        only_possible_value: DataIsIndex,
        union_value: struct { data: *Key.Union },
        bytes: struct { data: *Bytes },
        aggregate: struct {
            const @"data.ty.data.len orelse data.ty.data.fields_len" = opaque {};
            data: *Aggregate,
            @"trailing.element_values.len": *@"data.ty.data.len orelse data.ty.data.fields_len",
            trailing: struct { element_values: []Index },
        },
        repeated: struct { data: *Repeated },

        memoized_decl: struct { data: *Key.MemoizedDecl },
        memoized_call: struct {
            const @"data.args_len" = opaque {};
            data: *MemoizedCall,
            @"trailing.arg_values.len": *@"data.args_len",
            trailing: struct { arg_values: []Index },
        },
    }) void {
        _ = self;
        const map_fields = @typeInfo(@typeInfo(@TypeOf(tag_to_encoding_map)).Pointer.child).Struct.fields;
        @setEvalBranchQuota(2_000);
        inline for (@typeInfo(Tag).Enum.fields, 0..) |tag, start| {
            inline for (0..map_fields.len) |offset| {
                if (comptime std.mem.eql(u8, tag.name, map_fields[(start + offset) % map_fields.len].name)) break;
            } else {
                @compileError(@typeName(Tag) ++ "." ++ tag.name ++ " missing dbHelper tag_to_encoding_map entry");
            }
        }
    }

    comptime {
        if (builtin.mode == .Debug) {
            _ = dbHelper;
        }
    }
};

pub const static_keys = [_]Key{
    .{ .int_type = .{
        .signedness = .unsigned,
        .bits = 1,
    } },

    .{ .int_type = .{
        .signedness = .unsigned,
        .bits = 8,
    } },

    .{ .int_type = .{
        .signedness = .signed,
        .bits = 8,
    } },

    .{ .int_type = .{
        .signedness = .unsigned,
        .bits = 16,
    } },

    .{ .int_type = .{
        .signedness = .signed,
        .bits = 16,
    } },

    .{ .int_type = .{
        .signedness = .unsigned,
        .bits = 29,
    } },

    .{ .int_type = .{
        .signedness = .unsigned,
        .bits = 32,
    } },

    .{ .int_type = .{
        .signedness = .signed,
        .bits = 32,
    } },

    .{ .int_type = .{
        .signedness = .unsigned,
        .bits = 64,
    } },

    .{ .int_type = .{
        .signedness = .signed,
        .bits = 64,
    } },

    .{ .int_type = .{
        .signedness = .unsigned,
        .bits = 80,
    } },

    .{ .int_type = .{
        .signedness = .unsigned,
        .bits = 128,
    } },

    .{ .int_type = .{
        .signedness = .signed,
        .bits = 128,
    } },

    .{ .simple_type = .usize },
    .{ .simple_type = .isize },
    .{ .simple_type = .c_char },
    .{ .simple_type = .c_short },
    .{ .simple_type = .c_ushort },
    .{ .simple_type = .c_int },
    .{ .simple_type = .c_uint },
    .{ .simple_type = .c_long },
    .{ .simple_type = .c_ulong },
    .{ .simple_type = .c_longlong },
    .{ .simple_type = .c_ulonglong },
    .{ .simple_type = .c_longdouble },
    .{ .simple_type = .f16 },
    .{ .simple_type = .f32 },
    .{ .simple_type = .f64 },
    .{ .simple_type = .f80 },
    .{ .simple_type = .f128 },
    .{ .simple_type = .anyopaque },
    .{ .simple_type = .bool },
    .{ .simple_type = .void },
    .{ .simple_type = .type },
    .{ .simple_type = .anyerror },
    .{ .simple_type = .comptime_int },
    .{ .simple_type = .comptime_float },
    .{ .simple_type = .noreturn },
    .{ .anyframe_type = .none },
    .{ .simple_type = .null },
    .{ .simple_type = .undefined },
    .{ .simple_type = .enum_literal },
    .{ .simple_type = .atomic_order },
    .{ .simple_type = .atomic_rmw_op },
    .{ .simple_type = .calling_convention },
    .{ .simple_type = .address_space },
    .{ .simple_type = .float_mode },
    .{ .simple_type = .reduce_op },
    .{ .simple_type = .call_modifier },
    .{ .simple_type = .prefetch_options },
    .{ .simple_type = .export_options },
    .{ .simple_type = .extern_options },
    .{ .simple_type = .type_info },

    .{ .ptr_type = .{
        .elem_type = .u8_type,
        .size = .Many,
    } },

    // manyptr_const_u8_type
    .{ .ptr_type = .{
        .elem_type = .u8_type,
        .size = .Many,
        .is_const = true,
    } },

    // manyptr_const_u8_sentinel_0_type
    .{ .ptr_type = .{
        .elem_type = .u8_type,
        .sentinel = .zero_u8,
        .size = .Many,
        .is_const = true,
    } },

    .{ .ptr_type = .{
        .elem_type = .comptime_int_type,
        .size = .One,
        .is_const = true,
    } },

    // slice_const_u8_type
    .{ .ptr_type = .{
        .elem_type = .u8_type,
        .size = .Slice,
        .is_const = true,
    } },

    // slice_const_u8_sentinel_0_type
    .{ .ptr_type = .{
        .elem_type = .u8_type,
        .sentinel = .zero_u8,
        .size = .Slice,
        .is_const = true,
    } },

    // anyerror_void_error_union_type
    .{ .error_union_type = .{
        .error_set_type = .anyerror_type,
        .payload_type = .void_type,
    } },

    // generic_poison_type
    .{ .simple_type = .generic_poison },

    // empty_struct_type
    .{ .anon_struct_type = .{
        .types = &.{},
        .names = &.{},
        .values = &.{},
    } },

    .{ .simple_value = .undefined },

    .{ .int = .{
        .ty = .comptime_int_type,
        .storage = .{ .u64 = 0 },
    } },

    .{ .int = .{
        .ty = .usize_type,
        .storage = .{ .u64 = 0 },
    } },

    .{ .int = .{
        .ty = .u8_type,
        .storage = .{ .u64 = 0 },
    } },

    .{ .int = .{
        .ty = .comptime_int_type,
        .storage = .{ .u64 = 1 },
    } },

    .{ .int = .{
        .ty = .usize_type,
        .storage = .{ .u64 = 1 },
    } },

    // one_u8
    .{ .int = .{
        .ty = .u8_type,
        .storage = .{ .u64 = 1 },
    } },
    // four_u8
    .{ .int = .{
        .ty = .u8_type,
        .storage = .{ .u64 = 4 },
    } },
    // negative_one
    .{ .int = .{
        .ty = .comptime_int_type,
        .storage = .{ .i64 = -1 },
    } },
    // calling_convention_c
    .{ .enum_tag = .{
        .ty = .calling_convention_type,
        .int = .one_u8,
    } },
    // calling_convention_inline
    .{ .enum_tag = .{
        .ty = .calling_convention_type,
        .int = .four_u8,
    } },

    .{ .simple_value = .void },
    .{ .simple_value = .@"unreachable" },
    .{ .simple_value = .null },
    .{ .simple_value = .true },
    .{ .simple_value = .false },
    .{ .simple_value = .empty_struct },
    .{ .simple_value = .generic_poison },
};

/// How many items in the InternPool are statically known.
pub const static_len: u32 = static_keys.len;

pub const Tag = enum(u8) {
    /// An integer type.
    /// data is number of bits
    type_int_signed,
    /// An integer type.
    /// data is number of bits
    type_int_unsigned,
    /// An array type whose length requires 64 bits or which has a sentinel.
    /// data is payload to Array.
    type_array_big,
    /// An array type that has no sentinel and whose length fits in 32 bits.
    /// data is payload to Vector.
    type_array_small,
    /// A vector type.
    /// data is payload to Vector.
    type_vector,
    /// A fully explicitly specified pointer type.
    /// data is payload to Pointer.
    type_pointer,
    /// A slice type.
    /// data is Index of underlying pointer type.
    type_slice,
    /// An optional type.
    /// data is the child type.
    type_optional,
    /// The type `anyframe->T`.
    /// data is the child type.
    /// If the child type is `none`, the type is `anyframe`.
    type_anyframe,
    /// An error union type.
    /// data is payload to `Key.ErrorUnionType`.
    type_error_union,
    /// An error set type.
    /// data is payload to `ErrorSet`.
    type_error_set,
    /// The inferred error set type of a function.
    /// data is `Module.Fn.InferredErrorSet.Index`.
    type_inferred_error_set,
    /// An enum type with auto-numbered tag values.
    /// The enum is exhaustive.
    /// data is payload index to `EnumAuto`.
    type_enum_auto,
    /// An enum type with an explicitly provided integer tag type.
    /// The enum is exhaustive.
    /// data is payload index to `EnumExplicit`.
    type_enum_explicit,
    /// An enum type with an explicitly provided integer tag type.
    /// The enum is non-exhaustive.
    /// data is payload index to `EnumExplicit`.
    type_enum_nonexhaustive,
    /// A type that can be represented with only an enum tag.
    /// data is SimpleType enum value.
    simple_type,
    /// An opaque type.
    /// data is index of Key.OpaqueType in extra.
    type_opaque,
    /// A struct type.
    /// data is Module.Struct.OptionalIndex
    /// The `none` tag is used to represent `@TypeOf(.{})`.
    type_struct,
    /// A struct type that has only a namespace; no fields, and there is no
    /// Module.Struct object allocated for it.
    /// data is Module.Namespace.Index.
    type_struct_ns,
    /// An AnonStructType which stores types, names, and values for fields.
    /// data is extra index of `TypeStructAnon`.
    type_struct_anon,
    /// An AnonStructType which has only types and values for fields.
    /// data is extra index of `TypeStructAnon`.
    type_tuple_anon,
    /// A tagged union type.
    /// `data` is `Module.Union.Index`.
    type_union_tagged,
    /// An untagged union type. It also has no safety tag.
    /// `data` is `Module.Union.Index`.
    type_union_untagged,
    /// An untagged union type which has a safety tag.
    /// `data` is `Module.Union.Index`.
    type_union_safety,
    /// A function body type.
    /// `data` is extra index to `TypeFunction`.
    type_function,

    /// Typed `undefined`.
    /// `data` is `Index` of the type.
    /// Untyped `undefined` is stored instead via `simple_value`.
    undef,
    /// A wrapper for values which are comptime-known but should
    /// semantically be runtime-known.
    /// data is extra index of `TypeValue`.
    runtime_value,
    /// A value that can be represented with only an enum tag.
    /// data is SimpleValue enum value.
    simple_value,
    /// A pointer to a decl.
    /// data is extra index of `PtrDecl`, which contains the type and address.
    ptr_decl,
    /// A pointer to a decl that can be mutated at comptime.
    /// data is extra index of `PtrMutDecl`, which contains the type and address.
    ptr_mut_decl,
    /// data is extra index of `PtrComptimeField`, which contains the pointer type and field value.
    ptr_comptime_field,
    /// A pointer with an integer value.
    /// data is extra index of `PtrBase`, which contains the type and address.
    /// Only pointer types are allowed to have this encoding. Optional types must use
    /// `opt_payload` or `opt_null`.
    ptr_int,
    /// A pointer to the payload of an error union.
    /// data is extra index of `PtrBase`, which contains the type and base pointer.
    ptr_eu_payload,
    /// A pointer to the payload of an optional.
    /// data is extra index of `PtrBase`, which contains the type and base pointer.
    ptr_opt_payload,
    /// A pointer to an array element.
    /// data is extra index of PtrBaseIndex, which contains the base array and element index.
    /// In order to use this encoding, one must ensure that the `InternPool`
    /// already contains the elem pointer type corresponding to this payload.
    ptr_elem,
    /// A pointer to a container field.
    /// data is extra index of PtrBaseIndex, which contains the base container and field index.
    ptr_field,
    /// A slice.
    /// data is extra index of PtrSlice, which contains the ptr and len values
    ptr_slice,
    /// An optional value that is non-null.
    /// data is extra index of `TypeValue`.
    /// The type is the optional type (not the payload type).
    opt_payload,
    /// An optional value that is null.
    /// data is Index of the optional type.
    opt_null,
    /// Type: u8
    /// data is integer value
    int_u8,
    /// Type: u16
    /// data is integer value
    int_u16,
    /// Type: u32
    /// data is integer value
    int_u32,
    /// Type: i32
    /// data is integer value bitcasted to u32.
    int_i32,
    /// A usize that fits in 32 bits.
    /// data is integer value.
    int_usize,
    /// A comptime_int that fits in a u32.
    /// data is integer value.
    int_comptime_int_u32,
    /// A comptime_int that fits in an i32.
    /// data is integer value bitcasted to u32.
    int_comptime_int_i32,
    /// An integer value that fits in 32 bits with an explicitly provided type.
    /// data is extra index of `IntSmall`.
    int_small,
    /// A positive integer value.
    /// data is a limbs index to `Int`.
    int_positive,
    /// A negative integer value.
    /// data is a limbs index to `Int`.
    int_negative,
    /// The ABI alignment of a lazy type.
    /// data is extra index of `IntLazy`.
    int_lazy_align,
    /// The ABI size of a lazy type.
    /// data is extra index of `IntLazy`.
    int_lazy_size,
    /// An error value.
    /// data is extra index of `Key.Error`.
    error_set_error,
    /// An error union error.
    /// data is extra index of `Key.Error`.
    error_union_error,
    /// An error union payload.
    /// data is extra index of `TypeValue`.
    error_union_payload,
    /// An enum literal value.
    /// data is `NullTerminatedString` of the error name.
    enum_literal,
    /// An enum tag value.
    /// data is extra index of `Key.EnumTag`.
    enum_tag,
    /// An f16 value.
    /// data is float value bitcasted to u16 and zero-extended.
    float_f16,
    /// An f32 value.
    /// data is float value bitcasted to u32.
    float_f32,
    /// An f64 value.
    /// data is extra index to Float64.
    float_f64,
    /// An f80 value.
    /// data is extra index to Float80.
    float_f80,
    /// An f128 value.
    /// data is extra index to Float128.
    float_f128,
    /// A c_longdouble value of 80 bits.
    /// data is extra index to Float80.
    /// This is used when a c_longdouble value is provided as an f80, because f80 has unnormalized
    /// values which cannot be losslessly represented as f128. It should only be used when the type
    /// underlying c_longdouble for the target is 80 bits.
    float_c_longdouble_f80,
    /// A c_longdouble value of 128 bits.
    /// data is extra index to Float128.
    /// This is used when a c_longdouble value is provided as any type other than an f80, since all
    /// other float types can be losslessly converted to and from f128.
    float_c_longdouble_f128,
    /// A comptime_float value.
    /// data is extra index to Float128.
    float_comptime_float,
    /// A global variable.
    /// data is extra index to Variable.
    variable,
    /// An extern function.
    /// data is extra index to Key.ExternFunc.
    extern_func,
    /// A regular function.
    /// data is extra index to Key.Func.
    func,
    /// This represents the only possible value for *some* types which have
    /// only one possible value. Not all only-possible-values are encoded this way;
    /// for example structs which have all comptime fields are not encoded this way.
    /// The set of values that are encoded this way is:
    /// * An array or vector which has length 0.
    /// * A struct which has all fields comptime-known.
    /// data is Index of the type, which is known to be zero bits at runtime.
    only_possible_value,
    /// data is extra index to Key.Union.
    union_value,
    /// An array of bytes.
    /// data is extra index to `Bytes`.
    bytes,
    /// An instance of a struct, array, or vector.
    /// data is extra index to `Aggregate`.
    aggregate,
    /// An instance of an array or vector with every element being the same value.
    /// data is extra index to `Repeated`.
    repeated,

    /// A memoized declaration value.
    /// data is extra index to `Key.MemoizedDecl`
    memoized_decl,
    /// A memoized comptime function call result.
    /// data is extra index to `MemoizedCall`
    memoized_call,

    const ErrorUnionType = Key.ErrorUnionType;
    const OpaqueType = Key.OpaqueType;
    const TypeValue = Key.TypeValue;
    const Error = Key.Error;
    const EnumTag = Key.EnumTag;
    const ExternFunc = Key.ExternFunc;
    const Func = Key.Func;
    const Union = Key.Union;
    const MemoizedDecl = Key.MemoizedDecl;

    fn Payload(comptime tag: Tag) type {
        return switch (tag) {
            .type_int_signed => unreachable,
            .type_int_unsigned => unreachable,
            .type_array_big => Array,
            .type_array_small => Vector,
            .type_vector => Vector,
            .type_pointer => Pointer,
            .type_slice => unreachable,
            .type_optional => unreachable,
            .type_anyframe => unreachable,
            .type_error_union => ErrorUnionType,
            .type_error_set => ErrorSet,
            .type_inferred_error_set => unreachable,
            .type_enum_auto => EnumAuto,
            .type_enum_explicit => EnumExplicit,
            .type_enum_nonexhaustive => EnumExplicit,
            .simple_type => unreachable,
            .type_opaque => OpaqueType,
            .type_struct => unreachable,
            .type_struct_ns => unreachable,
            .type_struct_anon => TypeStructAnon,
            .type_tuple_anon => TypeStructAnon,
            .type_union_tagged => unreachable,
            .type_union_untagged => unreachable,
            .type_union_safety => unreachable,
            .type_function => TypeFunction,

            .undef => unreachable,
            .runtime_value => TypeValue,
            .simple_value => unreachable,
            .ptr_decl => PtrDecl,
            .ptr_mut_decl => PtrMutDecl,
            .ptr_comptime_field => PtrComptimeField,
            .ptr_int => PtrBase,
            .ptr_eu_payload => PtrBase,
            .ptr_opt_payload => PtrBase,
            .ptr_elem => PtrBaseIndex,
            .ptr_field => PtrBaseIndex,
            .ptr_slice => PtrSlice,
            .opt_payload => TypeValue,
            .opt_null => unreachable,
            .int_u8 => unreachable,
            .int_u16 => unreachable,
            .int_u32 => unreachable,
            .int_i32 => unreachable,
            .int_usize => unreachable,
            .int_comptime_int_u32 => unreachable,
            .int_comptime_int_i32 => unreachable,
            .int_small => IntSmall,
            .int_positive => unreachable,
            .int_negative => unreachable,
            .int_lazy_align => IntLazy,
            .int_lazy_size => IntLazy,
            .error_set_error => Error,
            .error_union_error => Error,
            .error_union_payload => TypeValue,
            .enum_literal => unreachable,
            .enum_tag => EnumTag,
            .float_f16 => unreachable,
            .float_f32 => unreachable,
            .float_f64 => unreachable,
            .float_f80 => unreachable,
            .float_f128 => unreachable,
            .float_c_longdouble_f80 => unreachable,
            .float_c_longdouble_f128 => unreachable,
            .float_comptime_float => unreachable,
            .variable => Variable,
            .extern_func => ExternFunc,
            .func => Func,
            .only_possible_value => unreachable,
            .union_value => Union,
            .bytes => Bytes,
            .aggregate => Aggregate,
            .repeated => Repeated,
            .memoized_decl => MemoizedDecl,
            .memoized_call => MemoizedCall,
        };
    }

    pub const Variable = struct {
        ty: Index,
        /// May be `none`.
        init: Index,
        decl: Module.Decl.Index,
        /// Library name if specified.
        /// For example `extern "c" var stderrp = ...` would have 'c' as library name.
        lib_name: OptionalNullTerminatedString,
        flags: Flags,

        pub const Flags = packed struct(u32) {
            is_extern: bool,
            is_const: bool,
            is_threadlocal: bool,
            is_weak_linkage: bool,
            _: u28 = 0,
        };
    };
};

/// Trailing:
/// 0. name: NullTerminatedString for each names_len
pub const ErrorSet = struct {
    names_len: u32,
    /// Maps error names to declaration index.
    names_map: MapIndex,
};

/// Trailing:
/// 0. param_type: Index for each params_len
pub const TypeFunction = struct {
    params_len: u32,
    return_type: Index,
    comptime_bits: u32,
    noalias_bits: u32,
    flags: Flags,

    pub const Flags = packed struct(u32) {
        alignment: Alignment,
        cc: std.builtin.CallingConvention,
        is_var_args: bool,
        is_generic: bool,
        is_noinline: bool,
        align_is_generic: bool,
        cc_is_generic: bool,
        section_is_generic: bool,
        addrspace_is_generic: bool,
        _: u11 = 0,
    };
};

pub const Bytes = struct {
    /// The type of the aggregate
    ty: Index,
    /// Index into string_bytes, of len ip.aggregateTypeLen(ty)
    bytes: String,
};

/// Trailing:
/// 0. element: Index for each len
/// len is determined by the aggregate type.
pub const Aggregate = struct {
    /// The type of the aggregate.
    ty: Index,
};

pub const Repeated = struct {
    /// The type of the aggregate.
    ty: Index,
    /// The value of every element.
    elem_val: Index,
};

/// Trailing:
/// 0. type: Index for each fields_len
/// 1. value: Index for each fields_len
/// 2. name: NullTerminatedString for each fields_len
/// The set of field names is omitted when the `Tag` is `type_tuple_anon`.
pub const TypeStructAnon = struct {
    fields_len: u32,
};

/// Having `SimpleType` and `SimpleValue` in separate enums makes it easier to
/// implement logic that only wants to deal with types because the logic can
/// ignore all simple values. Note that technically, types are values.
pub const SimpleType = enum(u32) {
    f16,
    f32,
    f64,
    f80,
    f128,
    usize,
    isize,
    c_char,
    c_short,
    c_ushort,
    c_int,
    c_uint,
    c_long,
    c_ulong,
    c_longlong,
    c_ulonglong,
    c_longdouble,
    anyopaque,
    bool,
    void,
    type,
    anyerror,
    comptime_int,
    comptime_float,
    noreturn,
    null,
    undefined,
    enum_literal,

    atomic_order,
    atomic_rmw_op,
    calling_convention,
    address_space,
    float_mode,
    reduce_op,
    call_modifier,
    prefetch_options,
    export_options,
    extern_options,
    type_info,

    generic_poison,
};

pub const SimpleValue = enum(u32) {
    /// This is untyped `undefined`.
    undefined,
    void,
    /// This is untyped `null`.
    null,
    /// This is the untyped empty struct literal: `.{}`
    empty_struct,
    true,
    false,
    @"unreachable",

    generic_poison,
};

pub const Pointer = struct {
    child: Index,
    sentinel: Index,
    flags: Flags,
    packed_offset: PackedOffset,

    pub const Flags = packed struct(u32) {
        size: Size,
        alignment: Alignment,
        is_const: bool,
        is_volatile: bool,
        is_allowzero: bool,
        address_space: AddressSpace,
        vector_index: VectorIndex,
    };

    pub const PackedOffset = packed struct(u32) {
        host_size: u16,
        bit_offset: u16,
    };

    pub const Size = std.builtin.Type.Pointer.Size;
    pub const AddressSpace = std.builtin.AddressSpace;
    pub const VectorIndex = Key.PtrType.VectorIndex;
};

/// Stored as a power-of-two, with one special value to indicate none.
pub const Alignment = enum(u6) {
    none = std.math.maxInt(u6),
    _,

    pub fn toByteUnitsOptional(a: Alignment) ?u64 {
        return switch (a) {
            .none => null,
            _ => @as(u64, 1) << @enumToInt(a),
        };
    }

    pub fn toByteUnits(a: Alignment, default: u64) u64 {
        return switch (a) {
            .none => default,
            _ => @as(u64, 1) << @enumToInt(a),
        };
    }

    pub fn fromByteUnits(n: u64) Alignment {
        if (n == 0) return .none;
        assert(std.math.isPowerOfTwo(n));
        return @intToEnum(Alignment, @ctz(n));
    }

    pub fn fromNonzeroByteUnits(n: u64) Alignment {
        assert(n != 0);
        return fromByteUnits(n);
    }

    pub fn min(a: Alignment, b: Alignment) Alignment {
        return @intToEnum(Alignment, @min(@enumToInt(a), @enumToInt(b)));
    }
};

/// Used for non-sentineled arrays that have length fitting in u32, as well as
/// vectors.
pub const Vector = struct {
    len: u32,
    child: Index,
};

pub const Array = struct {
    len0: u32,
    len1: u32,
    child: Index,
    sentinel: Index,

    pub const Length = PackedU64;

    pub fn getLength(a: Array) u64 {
        return (PackedU64{
            .a = a.len0,
            .b = a.len1,
        }).get();
    }
};

/// Trailing:
/// 0. field name: NullTerminatedString for each fields_len; declaration order
/// 1. tag value: Index for each fields_len; declaration order
pub const EnumExplicit = struct {
    /// The Decl that corresponds to the enum itself.
    decl: Module.Decl.Index,
    /// This may be `none` if there are no declarations.
    namespace: Module.Namespace.OptionalIndex,
    /// An integer type which is used for the numerical value of the enum, which
    /// has been explicitly provided by the enum declaration.
    int_tag_type: Index,
    fields_len: u32,
    /// Maps field names to declaration index.
    names_map: MapIndex,
    /// Maps field values to declaration index.
    /// If this is `none`, it means the trailing tag values are absent because
    /// they are auto-numbered.
    values_map: OptionalMapIndex,
};

/// Trailing:
/// 0. field name: NullTerminatedString for each fields_len; declaration order
pub const EnumAuto = struct {
    /// The Decl that corresponds to the enum itself.
    decl: Module.Decl.Index,
    /// This may be `none` if there are no declarations.
    namespace: Module.Namespace.OptionalIndex,
    /// An integer type which is used for the numerical value of the enum, which
    /// was inferred by Zig based on the number of tags.
    int_tag_type: Index,
    fields_len: u32,
    /// Maps field names to declaration index.
    names_map: MapIndex,
};

pub const PackedU64 = packed struct(u64) {
    a: u32,
    b: u32,

    pub fn get(x: PackedU64) u64 {
        return @bitCast(u64, x);
    }

    pub fn init(x: u64) PackedU64 {
        return @bitCast(PackedU64, x);
    }
};

pub const PtrDecl = struct {
    ty: Index,
    decl: Module.Decl.Index,
};

pub const PtrMutDecl = struct {
    ty: Index,
    decl: Module.Decl.Index,
    runtime_index: RuntimeIndex,
};

pub const PtrComptimeField = struct {
    ty: Index,
    field_val: Index,
};

pub const PtrBase = struct {
    ty: Index,
    base: Index,
};

pub const PtrBaseIndex = struct {
    ty: Index,
    base: Index,
    index: Index,
};

pub const PtrSlice = struct {
    /// The slice type.
    ty: Index,
    /// A many pointer value.
    ptr: Index,
    /// A usize value.
    len: Index,
};

/// Trailing: Limb for every limbs_len
pub const Int = struct {
    ty: Index,
    limbs_len: u32,
};

pub const IntSmall = struct {
    ty: Index,
    value: u32,
};

pub const IntLazy = struct {
    ty: Index,
    lazy_ty: Index,
};

/// A f64 value, broken up into 2 u32 parts.
pub const Float64 = struct {
    piece0: u32,
    piece1: u32,

    pub fn get(self: Float64) f64 {
        const int_bits = @as(u64, self.piece0) | (@as(u64, self.piece1) << 32);
        return @bitCast(f64, int_bits);
    }

    fn pack(val: f64) Float64 {
        const bits = @bitCast(u64, val);
        return .{
            .piece0 = @truncate(u32, bits),
            .piece1 = @truncate(u32, bits >> 32),
        };
    }
};

/// A f80 value, broken up into 2 u32 parts and a u16 part zero-padded to a u32.
pub const Float80 = struct {
    piece0: u32,
    piece1: u32,
    piece2: u32, // u16 part, top bits

    pub fn get(self: Float80) f80 {
        const int_bits = @as(u80, self.piece0) |
            (@as(u80, self.piece1) << 32) |
            (@as(u80, self.piece2) << 64);
        return @bitCast(f80, int_bits);
    }

    fn pack(val: f80) Float80 {
        const bits = @bitCast(u80, val);
        return .{
            .piece0 = @truncate(u32, bits),
            .piece1 = @truncate(u32, bits >> 32),
            .piece2 = @truncate(u16, bits >> 64),
        };
    }
};

/// A f128 value, broken up into 4 u32 parts.
pub const Float128 = struct {
    piece0: u32,
    piece1: u32,
    piece2: u32,
    piece3: u32,

    pub fn get(self: Float128) f128 {
        const int_bits = @as(u128, self.piece0) |
            (@as(u128, self.piece1) << 32) |
            (@as(u128, self.piece2) << 64) |
            (@as(u128, self.piece3) << 96);
        return @bitCast(f128, int_bits);
    }

    fn pack(val: f128) Float128 {
        const bits = @bitCast(u128, val);
        return .{
            .piece0 = @truncate(u32, bits),
            .piece1 = @truncate(u32, bits >> 32),
            .piece2 = @truncate(u32, bits >> 64),
            .piece3 = @truncate(u32, bits >> 96),
        };
    }
};

/// Trailing:
/// 0. arg value: Index for each args_len
pub const MemoizedCall = struct {
    func: Module.Fn.Index,
    args_len: u32,
    result: Index,
};

pub fn init(ip: *InternPool, gpa: Allocator) !void {
    assert(ip.items.len == 0);

    // So that we can use `catch unreachable` below.
    try ip.items.ensureUnusedCapacity(gpa, static_keys.len);
    try ip.map.ensureUnusedCapacity(gpa, static_keys.len);
    try ip.extra.ensureUnusedCapacity(gpa, static_keys.len);

    // This inserts all the statically-known values into the intern pool in the
    // order expected.
    for (static_keys) |key| _ = ip.get(gpa, key) catch unreachable;

    if (std.debug.runtime_safety) {
        // Sanity check.
        assert(ip.indexToKey(.bool_true).simple_value == .true);
        assert(ip.indexToKey(.bool_false).simple_value == .false);

        const cc_inline = ip.indexToKey(.calling_convention_inline).enum_tag.int;
        const cc_c = ip.indexToKey(.calling_convention_c).enum_tag.int;

        assert(ip.indexToKey(cc_inline).int.storage.u64 ==
            @enumToInt(std.builtin.CallingConvention.Inline));

        assert(ip.indexToKey(cc_c).int.storage.u64 ==
            @enumToInt(std.builtin.CallingConvention.C));

        assert(ip.indexToKey(ip.typeOf(cc_inline)).int_type.bits ==
            @typeInfo(@typeInfo(std.builtin.CallingConvention).Enum.tag_type).Int.bits);
    }

    assert(ip.items.len == static_keys.len);
}

pub fn deinit(ip: *InternPool, gpa: Allocator) void {
    ip.map.deinit(gpa);
    ip.items.deinit(gpa);
    ip.extra.deinit(gpa);
    ip.limbs.deinit(gpa);
    ip.string_bytes.deinit(gpa);

    ip.structs_free_list.deinit(gpa);
    ip.allocated_structs.deinit(gpa);

    ip.unions_free_list.deinit(gpa);
    ip.allocated_unions.deinit(gpa);

    ip.funcs_free_list.deinit(gpa);
    ip.allocated_funcs.deinit(gpa);

    ip.inferred_error_sets_free_list.deinit(gpa);
    ip.allocated_inferred_error_sets.deinit(gpa);

    for (ip.maps.items) |*map| map.deinit(gpa);
    ip.maps.deinit(gpa);

    ip.string_table.deinit(gpa);

    ip.* = undefined;
}

pub fn indexToKey(ip: *const InternPool, index: Index) Key {
    assert(index != .none);
    const item = ip.items.get(@enumToInt(index));
    const data = item.data;
    return switch (item.tag) {
        .type_int_signed => .{
            .int_type = .{
                .signedness = .signed,
                .bits = @intCast(u16, data),
            },
        },
        .type_int_unsigned => .{
            .int_type = .{
                .signedness = .unsigned,
                .bits = @intCast(u16, data),
            },
        },
        .type_array_big => {
            const array_info = ip.extraData(Array, data);
            return .{ .array_type = .{
                .len = array_info.getLength(),
                .child = array_info.child,
                .sentinel = array_info.sentinel,
            } };
        },
        .type_array_small => {
            const array_info = ip.extraData(Vector, data);
            return .{ .array_type = .{
                .len = array_info.len,
                .child = array_info.child,
                .sentinel = .none,
            } };
        },
        .simple_type => .{ .simple_type = @intToEnum(SimpleType, data) },
        .simple_value => .{ .simple_value = @intToEnum(SimpleValue, data) },

        .type_vector => {
            const vector_info = ip.extraData(Vector, data);
            return .{ .vector_type = .{
                .len = vector_info.len,
                .child = vector_info.child,
            } };
        },

        .type_pointer => {
            const ptr_info = ip.extraData(Pointer, data);
            return .{ .ptr_type = .{
                .elem_type = ptr_info.child,
                .sentinel = ptr_info.sentinel,
                .alignment = ptr_info.flags.alignment,
                .size = ptr_info.flags.size,
                .is_const = ptr_info.flags.is_const,
                .is_volatile = ptr_info.flags.is_volatile,
                .is_allowzero = ptr_info.flags.is_allowzero,
                .address_space = ptr_info.flags.address_space,
                .vector_index = ptr_info.flags.vector_index,
                .host_size = ptr_info.packed_offset.host_size,
                .bit_offset = ptr_info.packed_offset.bit_offset,
            } };
        },

        .type_slice => {
            assert(ip.items.items(.tag)[data] == .type_pointer);
            const ptr_info = ip.extraData(Pointer, ip.items.items(.data)[data]);
            return .{ .ptr_type = .{
                .elem_type = ptr_info.child,
                .sentinel = ptr_info.sentinel,
                .alignment = ptr_info.flags.alignment,
                .size = .Slice,
                .is_const = ptr_info.flags.is_const,
                .is_volatile = ptr_info.flags.is_volatile,
                .is_allowzero = ptr_info.flags.is_allowzero,
                .address_space = ptr_info.flags.address_space,
                .vector_index = ptr_info.flags.vector_index,
                .host_size = ptr_info.packed_offset.host_size,
                .bit_offset = ptr_info.packed_offset.bit_offset,
            } };
        },

        .type_optional => .{ .opt_type = @intToEnum(Index, data) },
        .type_anyframe => .{ .anyframe_type = @intToEnum(Index, data) },

        .type_error_union => .{ .error_union_type = ip.extraData(Key.ErrorUnionType, data) },
        .type_error_set => {
            const error_set = ip.extraDataTrail(ErrorSet, data);
            const names_len = error_set.data.names_len;
            const names = ip.extra.items[error_set.end..][0..names_len];
            return .{ .error_set_type = .{
                .names = @ptrCast([]const NullTerminatedString, names),
                .names_map = error_set.data.names_map.toOptional(),
            } };
        },
        .type_inferred_error_set => .{
            .inferred_error_set_type = @intToEnum(Module.Fn.InferredErrorSet.Index, data),
        },

        .type_opaque => .{ .opaque_type = ip.extraData(Key.OpaqueType, data) },
        .type_struct => {
            const struct_index = @intToEnum(Module.Struct.OptionalIndex, data);
            const namespace = if (struct_index.unwrap()) |i|
                ip.structPtrConst(i).namespace.toOptional()
            else
                .none;
            return .{ .struct_type = .{
                .index = struct_index,
                .namespace = namespace,
            } };
        },
        .type_struct_ns => .{ .struct_type = .{
            .index = .none,
            .namespace = @intToEnum(Module.Namespace.Index, data).toOptional(),
        } },

        .type_struct_anon => {
            const type_struct_anon = ip.extraDataTrail(TypeStructAnon, data);
            const fields_len = type_struct_anon.data.fields_len;
            const types = ip.extra.items[type_struct_anon.end..][0..fields_len];
            const values = ip.extra.items[type_struct_anon.end + fields_len ..][0..fields_len];
            const names = ip.extra.items[type_struct_anon.end + 2 * fields_len ..][0..fields_len];
            return .{ .anon_struct_type = .{
                .types = @ptrCast([]const Index, types),
                .values = @ptrCast([]const Index, values),
                .names = @ptrCast([]const NullTerminatedString, names),
            } };
        },
        .type_tuple_anon => {
            const type_struct_anon = ip.extraDataTrail(TypeStructAnon, data);
            const fields_len = type_struct_anon.data.fields_len;
            const types = ip.extra.items[type_struct_anon.end..][0..fields_len];
            const values = ip.extra.items[type_struct_anon.end + fields_len ..][0..fields_len];
            return .{ .anon_struct_type = .{
                .types = @ptrCast([]const Index, types),
                .values = @ptrCast([]const Index, values),
                .names = &.{},
            } };
        },

        .type_union_untagged => .{ .union_type = .{
            .index = @intToEnum(Module.Union.Index, data),
            .runtime_tag = .none,
        } },
        .type_union_tagged => .{ .union_type = .{
            .index = @intToEnum(Module.Union.Index, data),
            .runtime_tag = .tagged,
        } },
        .type_union_safety => .{ .union_type = .{
            .index = @intToEnum(Module.Union.Index, data),
            .runtime_tag = .safety,
        } },

        .type_enum_auto => {
            const enum_auto = ip.extraDataTrail(EnumAuto, data);
            const names = @ptrCast(
                []const NullTerminatedString,
                ip.extra.items[enum_auto.end..][0..enum_auto.data.fields_len],
            );
            return .{ .enum_type = .{
                .decl = enum_auto.data.decl,
                .namespace = enum_auto.data.namespace,
                .tag_ty = enum_auto.data.int_tag_type,
                .names = names,
                .values = &.{},
                .tag_mode = .auto,
                .names_map = enum_auto.data.names_map.toOptional(),
                .values_map = .none,
            } };
        },
        .type_enum_explicit => ip.indexToKeyEnum(data, .explicit),
        .type_enum_nonexhaustive => ip.indexToKeyEnum(data, .nonexhaustive),
        .type_function => .{ .func_type = ip.indexToKeyFuncType(data) },

        .undef => .{ .undef = @intToEnum(Index, data) },
        .runtime_value => .{ .runtime_value = ip.extraData(Tag.TypeValue, data) },
        .opt_null => .{ .opt = .{
            .ty = @intToEnum(Index, data),
            .val = .none,
        } },
        .opt_payload => {
            const extra = ip.extraData(Tag.TypeValue, data);
            return .{ .opt = .{
                .ty = extra.ty,
                .val = extra.val,
            } };
        },
        .ptr_decl => {
            const info = ip.extraData(PtrDecl, data);
            return .{ .ptr = .{
                .ty = info.ty,
                .addr = .{ .decl = info.decl },
            } };
        },
        .ptr_mut_decl => {
            const info = ip.extraData(PtrMutDecl, data);
            return .{ .ptr = .{
                .ty = info.ty,
                .addr = .{ .mut_decl = .{
                    .decl = info.decl,
                    .runtime_index = info.runtime_index,
                } },
            } };
        },
        .ptr_comptime_field => {
            const info = ip.extraData(PtrComptimeField, data);
            return .{ .ptr = .{
                .ty = info.ty,
                .addr = .{ .comptime_field = info.field_val },
            } };
        },
        .ptr_int => {
            const info = ip.extraData(PtrBase, data);
            return .{ .ptr = .{
                .ty = info.ty,
                .addr = .{ .int = info.base },
            } };
        },
        .ptr_eu_payload => {
            const info = ip.extraData(PtrBase, data);
            return .{ .ptr = .{
                .ty = info.ty,
                .addr = .{ .eu_payload = info.base },
            } };
        },
        .ptr_opt_payload => {
            const info = ip.extraData(PtrBase, data);
            return .{ .ptr = .{
                .ty = info.ty,
                .addr = .{ .opt_payload = info.base },
            } };
        },
        .ptr_elem => {
            // Avoid `indexToKey` recursion by asserting the tag encoding.
            const info = ip.extraData(PtrBaseIndex, data);
            const index_item = ip.items.get(@enumToInt(info.index));
            return switch (index_item.tag) {
                .int_usize => .{ .ptr = .{
                    .ty = info.ty,
                    .addr = .{ .elem = .{
                        .base = info.base,
                        .index = index_item.data,
                    } },
                } },
                .int_positive => @panic("TODO"), // implement along with behavior test coverage
                else => unreachable,
            };
        },
        .ptr_field => {
            // Avoid `indexToKey` recursion by asserting the tag encoding.
            const info = ip.extraData(PtrBaseIndex, data);
            const index_item = ip.items.get(@enumToInt(info.index));
            return switch (index_item.tag) {
                .int_usize => .{ .ptr = .{
                    .ty = info.ty,
                    .addr = .{ .field = .{
                        .base = info.base,
                        .index = index_item.data,
                    } },
                } },
                .int_positive => @panic("TODO"), // implement along with behavior test coverage
                else => unreachable,
            };
        },
        .ptr_slice => {
            const info = ip.extraData(PtrSlice, data);
            const ptr_item = ip.items.get(@enumToInt(info.ptr));
            return .{
                .ptr = .{
                    .ty = info.ty,
                    .addr = switch (ptr_item.tag) {
                        .ptr_decl => .{
                            .decl = ip.extraData(PtrDecl, ptr_item.data).decl,
                        },
                        .ptr_mut_decl => b: {
                            const sub_info = ip.extraData(PtrMutDecl, ptr_item.data);
                            break :b .{ .mut_decl = .{
                                .decl = sub_info.decl,
                                .runtime_index = sub_info.runtime_index,
                            } };
                        },
                        .ptr_comptime_field => .{
                            .comptime_field = ip.extraData(PtrComptimeField, ptr_item.data).field_val,
                        },
                        .ptr_int => .{
                            .int = ip.extraData(PtrBase, ptr_item.data).base,
                        },
                        .ptr_eu_payload => .{
                            .eu_payload = ip.extraData(PtrBase, ptr_item.data).base,
                        },
                        .ptr_opt_payload => .{
                            .opt_payload = ip.extraData(PtrBase, ptr_item.data).base,
                        },
                        .ptr_elem => b: {
                            // Avoid `indexToKey` recursion by asserting the tag encoding.
                            const sub_info = ip.extraData(PtrBaseIndex, ptr_item.data);
                            const index_item = ip.items.get(@enumToInt(sub_info.index));
                            break :b switch (index_item.tag) {
                                .int_usize => .{ .elem = .{
                                    .base = sub_info.base,
                                    .index = index_item.data,
                                } },
                                .int_positive => @panic("TODO"), // implement along with behavior test coverage
                                else => unreachable,
                            };
                        },
                        .ptr_field => b: {
                            // Avoid `indexToKey` recursion by asserting the tag encoding.
                            const sub_info = ip.extraData(PtrBaseIndex, ptr_item.data);
                            const index_item = ip.items.get(@enumToInt(sub_info.index));
                            break :b switch (index_item.tag) {
                                .int_usize => .{ .field = .{
                                    .base = sub_info.base,
                                    .index = index_item.data,
                                } },
                                .int_positive => @panic("TODO"), // implement along with behavior test coverage
                                else => unreachable,
                            };
                        },
                        else => unreachable,
                    },
                    .len = info.len,
                },
            };
        },
        .int_u8 => .{ .int = .{
            .ty = .u8_type,
            .storage = .{ .u64 = data },
        } },
        .int_u16 => .{ .int = .{
            .ty = .u16_type,
            .storage = .{ .u64 = data },
        } },
        .int_u32 => .{ .int = .{
            .ty = .u32_type,
            .storage = .{ .u64 = data },
        } },
        .int_i32 => .{ .int = .{
            .ty = .i32_type,
            .storage = .{ .i64 = @bitCast(i32, data) },
        } },
        .int_usize => .{ .int = .{
            .ty = .usize_type,
            .storage = .{ .u64 = data },
        } },
        .int_comptime_int_u32 => .{ .int = .{
            .ty = .comptime_int_type,
            .storage = .{ .u64 = data },
        } },
        .int_comptime_int_i32 => .{ .int = .{
            .ty = .comptime_int_type,
            .storage = .{ .i64 = @bitCast(i32, data) },
        } },
        .int_positive => ip.indexToKeyBigInt(data, true),
        .int_negative => ip.indexToKeyBigInt(data, false),
        .int_small => {
            const info = ip.extraData(IntSmall, data);
            return .{ .int = .{
                .ty = info.ty,
                .storage = .{ .u64 = info.value },
            } };
        },
        .int_lazy_align, .int_lazy_size => |tag| {
            const info = ip.extraData(IntLazy, data);
            return .{ .int = .{
                .ty = info.ty,
                .storage = switch (tag) {
                    .int_lazy_align => .{ .lazy_align = info.lazy_ty },
                    .int_lazy_size => .{ .lazy_size = info.lazy_ty },
                    else => unreachable,
                },
            } };
        },
        .float_f16 => .{ .float = .{
            .ty = .f16_type,
            .storage = .{ .f16 = @bitCast(f16, @intCast(u16, data)) },
        } },
        .float_f32 => .{ .float = .{
            .ty = .f32_type,
            .storage = .{ .f32 = @bitCast(f32, data) },
        } },
        .float_f64 => .{ .float = .{
            .ty = .f64_type,
            .storage = .{ .f64 = ip.extraData(Float64, data).get() },
        } },
        .float_f80 => .{ .float = .{
            .ty = .f80_type,
            .storage = .{ .f80 = ip.extraData(Float80, data).get() },
        } },
        .float_f128 => .{ .float = .{
            .ty = .f128_type,
            .storage = .{ .f128 = ip.extraData(Float128, data).get() },
        } },
        .float_c_longdouble_f80 => .{ .float = .{
            .ty = .c_longdouble_type,
            .storage = .{ .f80 = ip.extraData(Float80, data).get() },
        } },
        .float_c_longdouble_f128 => .{ .float = .{
            .ty = .c_longdouble_type,
            .storage = .{ .f128 = ip.extraData(Float128, data).get() },
        } },
        .float_comptime_float => .{ .float = .{
            .ty = .comptime_float_type,
            .storage = .{ .f128 = ip.extraData(Float128, data).get() },
        } },
        .variable => {
            const extra = ip.extraData(Tag.Variable, data);
            return .{ .variable = .{
                .ty = extra.ty,
                .init = extra.init,
                .decl = extra.decl,
                .lib_name = extra.lib_name,
                .is_extern = extra.flags.is_extern,
                .is_const = extra.flags.is_const,
                .is_threadlocal = extra.flags.is_threadlocal,
                .is_weak_linkage = extra.flags.is_weak_linkage,
            } };
        },
        .extern_func => .{ .extern_func = ip.extraData(Key.ExternFunc, data) },
        .func => .{ .func = ip.extraData(Key.Func, data) },
        .only_possible_value => {
            const ty = @intToEnum(Index, data);
            const ty_item = ip.items.get(@enumToInt(ty));
            return switch (ty_item.tag) {
                .type_array_big, .type_array_small, .type_vector => .{ .aggregate = .{
                    .ty = ty,
                    .storage = .{ .elems = &.{} },
                } },
                // TODO: migrate structs to properly use the InternPool rather
                // than using the SegmentedList trick, then the struct type will
                // have a slice of comptime values that can be used here for when
                // the struct has one possible value due to all fields comptime (same
                // as the tuple case below).
                .type_struct, .type_struct_ns => .{ .aggregate = .{
                    .ty = ty,
                    .storage = .{ .elems = &.{} },
                } },

                // There is only one possible value precisely due to the
                // fact that this values slice is fully populated!
                .type_struct_anon, .type_tuple_anon => {
                    const type_struct_anon = ip.extraDataTrail(TypeStructAnon, ty_item.data);
                    const fields_len = type_struct_anon.data.fields_len;
                    const values = ip.extra.items[type_struct_anon.end + fields_len ..][0..fields_len];
                    return .{ .aggregate = .{
                        .ty = ty,
                        .storage = .{ .elems = @ptrCast([]const Index, values) },
                    } };
                },

                else => unreachable,
            };
        },
        .bytes => {
            const extra = ip.extraData(Bytes, data);
            const len = @intCast(u32, ip.aggregateTypeLenIncludingSentinel(extra.ty));
            return .{ .aggregate = .{
                .ty = extra.ty,
                .storage = .{ .bytes = ip.string_bytes.items[@enumToInt(extra.bytes)..][0..len] },
            } };
        },
        .aggregate => {
            const extra = ip.extraDataTrail(Aggregate, data);
            const len = @intCast(u32, ip.aggregateTypeLenIncludingSentinel(extra.data.ty));
            const fields = @ptrCast([]const Index, ip.extra.items[extra.end..][0..len]);
            return .{ .aggregate = .{
                .ty = extra.data.ty,
                .storage = .{ .elems = fields },
            } };
        },
        .repeated => {
            const extra = ip.extraData(Repeated, data);
            return .{ .aggregate = .{
                .ty = extra.ty,
                .storage = .{ .repeated_elem = extra.elem_val },
            } };
        },
        .union_value => .{ .un = ip.extraData(Key.Union, data) },
        .error_set_error => .{ .err = ip.extraData(Key.Error, data) },
        .error_union_error => {
            const extra = ip.extraData(Key.Error, data);
            return .{ .error_union = .{
                .ty = extra.ty,
                .val = .{ .err_name = extra.name },
            } };
        },
        .error_union_payload => {
            const extra = ip.extraData(Tag.TypeValue, data);
            return .{ .error_union = .{
                .ty = extra.ty,
                .val = .{ .payload = extra.val },
            } };
        },
        .enum_literal => .{ .enum_literal = @intToEnum(NullTerminatedString, data) },
        .enum_tag => .{ .enum_tag = ip.extraData(Key.EnumTag, data) },

        .memoized_decl => .{ .memoized_decl = ip.extraData(Key.MemoizedDecl, data) },
        .memoized_call => {
            const extra = ip.extraDataTrail(MemoizedCall, data);
            return .{ .memoized_call = .{
                .func = extra.data.func,
                .arg_values = @ptrCast([]const Index, ip.extra.items[extra.end..][0..extra.data.args_len]),
                .result = extra.data.result,
            } };
        },
    };
}

fn indexToKeyFuncType(ip: *const InternPool, data: u32) Key.FuncType {
    const type_function = ip.extraDataTrail(TypeFunction, data);
    const param_types = @ptrCast(
        []Index,
        ip.extra.items[type_function.end..][0..type_function.data.params_len],
    );
    return .{
        .param_types = param_types,
        .return_type = type_function.data.return_type,
        .comptime_bits = type_function.data.comptime_bits,
        .noalias_bits = type_function.data.noalias_bits,
        .alignment = type_function.data.flags.alignment,
        .cc = type_function.data.flags.cc,
        .is_var_args = type_function.data.flags.is_var_args,
        .is_generic = type_function.data.flags.is_generic,
        .is_noinline = type_function.data.flags.is_noinline,
        .align_is_generic = type_function.data.flags.align_is_generic,
        .cc_is_generic = type_function.data.flags.cc_is_generic,
        .section_is_generic = type_function.data.flags.section_is_generic,
        .addrspace_is_generic = type_function.data.flags.addrspace_is_generic,
    };
}

fn indexToKeyEnum(ip: *const InternPool, data: u32, tag_mode: Key.EnumType.TagMode) Key {
    const enum_explicit = ip.extraDataTrail(EnumExplicit, data);
    const names = @ptrCast(
        []const NullTerminatedString,
        ip.extra.items[enum_explicit.end..][0..enum_explicit.data.fields_len],
    );
    const values = if (enum_explicit.data.values_map != .none) @ptrCast(
        []const Index,
        ip.extra.items[enum_explicit.end + names.len ..][0..enum_explicit.data.fields_len],
    ) else &[0]Index{};

    return .{ .enum_type = .{
        .decl = enum_explicit.data.decl,
        .namespace = enum_explicit.data.namespace,
        .tag_ty = enum_explicit.data.int_tag_type,
        .names = names,
        .values = values,
        .tag_mode = tag_mode,
        .names_map = enum_explicit.data.names_map.toOptional(),
        .values_map = enum_explicit.data.values_map,
    } };
}

fn indexToKeyBigInt(ip: *const InternPool, limb_index: u32, positive: bool) Key {
    const int_info = ip.limbData(Int, limb_index);
    return .{ .int = .{
        .ty = int_info.ty,
        .storage = .{ .big_int = .{
            .limbs = ip.limbSlice(Int, limb_index, int_info.limbs_len),
            .positive = positive,
        } },
    } };
}

pub fn get(ip: *InternPool, gpa: Allocator, key: Key) Allocator.Error!Index {
    const adapter: KeyAdapter = .{ .intern_pool = ip };
    const gop = try ip.map.getOrPutAdapted(gpa, key, adapter);
    if (gop.found_existing) return @intToEnum(Index, gop.index);
    try ip.items.ensureUnusedCapacity(gpa, 1);
    switch (key) {
        .int_type => |int_type| {
            const t: Tag = switch (int_type.signedness) {
                .signed => .type_int_signed,
                .unsigned => .type_int_unsigned,
            };
            ip.items.appendAssumeCapacity(.{
                .tag = t,
                .data = int_type.bits,
            });
        },
        .ptr_type => |ptr_type| {
            assert(ptr_type.elem_type != .none);
            assert(ptr_type.sentinel == .none or ip.typeOf(ptr_type.sentinel) == ptr_type.elem_type);

            if (ptr_type.size == .Slice) {
                _ = ip.map.pop();
                var new_key = key;
                new_key.ptr_type.size = .Many;
                const ptr_type_index = try ip.get(gpa, new_key);
                assert(!(try ip.map.getOrPutAdapted(gpa, key, adapter)).found_existing);
                try ip.items.ensureUnusedCapacity(gpa, 1);
                ip.items.appendAssumeCapacity(.{
                    .tag = .type_slice,
                    .data = @enumToInt(ptr_type_index),
                });
                return @intToEnum(Index, ip.items.len - 1);
            }

            const is_allowzero = ptr_type.is_allowzero or ptr_type.size == .C;

            ip.items.appendAssumeCapacity(.{
                .tag = .type_pointer,
                .data = try ip.addExtra(gpa, Pointer{
                    .child = ptr_type.elem_type,
                    .sentinel = ptr_type.sentinel,
                    .flags = .{
                        .alignment = ptr_type.alignment,
                        .is_const = ptr_type.is_const,
                        .is_volatile = ptr_type.is_volatile,
                        .is_allowzero = is_allowzero,
                        .size = ptr_type.size,
                        .address_space = ptr_type.address_space,
                        .vector_index = ptr_type.vector_index,
                    },
                    .packed_offset = .{
                        .host_size = ptr_type.host_size,
                        .bit_offset = ptr_type.bit_offset,
                    },
                }),
            });
        },
        .array_type => |array_type| {
            assert(array_type.child != .none);
            assert(array_type.sentinel == .none or ip.typeOf(array_type.sentinel) == array_type.child);

            if (std.math.cast(u32, array_type.len)) |len| {
                if (array_type.sentinel == .none) {
                    ip.items.appendAssumeCapacity(.{
                        .tag = .type_array_small,
                        .data = try ip.addExtra(gpa, Vector{
                            .len = len,
                            .child = array_type.child,
                        }),
                    });
                    return @intToEnum(Index, ip.items.len - 1);
                }
            }

            const length = Array.Length.init(array_type.len);
            ip.items.appendAssumeCapacity(.{
                .tag = .type_array_big,
                .data = try ip.addExtra(gpa, Array{
                    .len0 = length.a,
                    .len1 = length.b,
                    .child = array_type.child,
                    .sentinel = array_type.sentinel,
                }),
            });
        },
        .vector_type => |vector_type| {
            ip.items.appendAssumeCapacity(.{
                .tag = .type_vector,
                .data = try ip.addExtra(gpa, Vector{
                    .len = vector_type.len,
                    .child = vector_type.child,
                }),
            });
        },
        .opt_type => |payload_type| {
            assert(payload_type != .none);
            ip.items.appendAssumeCapacity(.{
                .tag = .type_optional,
                .data = @enumToInt(payload_type),
            });
        },
        .anyframe_type => |payload_type| {
            // payload_type might be none, indicating the type is `anyframe`.
            ip.items.appendAssumeCapacity(.{
                .tag = .type_anyframe,
                .data = @enumToInt(payload_type),
            });
        },
        .error_union_type => |error_union_type| {
            ip.items.appendAssumeCapacity(.{
                .tag = .type_error_union,
                .data = try ip.addExtra(gpa, error_union_type),
            });
        },
        .error_set_type => |error_set_type| {
            assert(error_set_type.names_map == .none);
            assert(std.sort.isSorted(NullTerminatedString, error_set_type.names, {}, NullTerminatedString.indexLessThan));
            const names_map = try ip.addMap(gpa);
            try addStringsToMap(ip, gpa, names_map, error_set_type.names);
            const names_len = @intCast(u32, error_set_type.names.len);
            try ip.extra.ensureUnusedCapacity(gpa, @typeInfo(ErrorSet).Struct.fields.len + names_len);
            ip.items.appendAssumeCapacity(.{
                .tag = .type_error_set,
                .data = ip.addExtraAssumeCapacity(ErrorSet{
                    .names_len = names_len,
                    .names_map = names_map,
                }),
            });
            ip.extra.appendSliceAssumeCapacity(@ptrCast([]const u32, error_set_type.names));
        },
        .inferred_error_set_type => |ies_index| {
            ip.items.appendAssumeCapacity(.{
                .tag = .type_inferred_error_set,
                .data = @enumToInt(ies_index),
            });
        },
        .simple_type => |simple_type| {
            ip.items.appendAssumeCapacity(.{
                .tag = .simple_type,
                .data = @enumToInt(simple_type),
            });
        },
        .simple_value => |simple_value| {
            ip.items.appendAssumeCapacity(.{
                .tag = .simple_value,
                .data = @enumToInt(simple_value),
            });
        },
        .undef => |ty| {
            assert(ty != .none);
            ip.items.appendAssumeCapacity(.{
                .tag = .undef,
                .data = @enumToInt(ty),
            });
        },
        .runtime_value => |runtime_value| {
            assert(runtime_value.ty == ip.typeOf(runtime_value.val));
            ip.items.appendAssumeCapacity(.{
                .tag = .runtime_value,
                .data = try ip.addExtra(gpa, runtime_value),
            });
        },

        .struct_type => |struct_type| {
            ip.items.appendAssumeCapacity(if (struct_type.index.unwrap()) |i| .{
                .tag = .type_struct,
                .data = @enumToInt(i),
            } else if (struct_type.namespace.unwrap()) |i| .{
                .tag = .type_struct_ns,
                .data = @enumToInt(i),
            } else .{
                .tag = .type_struct,
                .data = @enumToInt(Module.Struct.OptionalIndex.none),
            });
        },

        .anon_struct_type => |anon_struct_type| {
            assert(anon_struct_type.types.len == anon_struct_type.values.len);
            for (anon_struct_type.types) |elem| assert(elem != .none);

            const fields_len = @intCast(u32, anon_struct_type.types.len);
            if (anon_struct_type.names.len == 0) {
                try ip.extra.ensureUnusedCapacity(
                    gpa,
                    @typeInfo(TypeStructAnon).Struct.fields.len + (fields_len * 2),
                );
                ip.items.appendAssumeCapacity(.{
                    .tag = .type_tuple_anon,
                    .data = ip.addExtraAssumeCapacity(TypeStructAnon{
                        .fields_len = fields_len,
                    }),
                });
                ip.extra.appendSliceAssumeCapacity(@ptrCast([]const u32, anon_struct_type.types));
                ip.extra.appendSliceAssumeCapacity(@ptrCast([]const u32, anon_struct_type.values));
                return @intToEnum(Index, ip.items.len - 1);
            }

            assert(anon_struct_type.names.len == anon_struct_type.types.len);

            try ip.extra.ensureUnusedCapacity(
                gpa,
                @typeInfo(TypeStructAnon).Struct.fields.len + (fields_len * 3),
            );
            ip.items.appendAssumeCapacity(.{
                .tag = .type_struct_anon,
                .data = ip.addExtraAssumeCapacity(TypeStructAnon{
                    .fields_len = fields_len,
                }),
            });
            ip.extra.appendSliceAssumeCapacity(@ptrCast([]const u32, anon_struct_type.types));
            ip.extra.appendSliceAssumeCapacity(@ptrCast([]const u32, anon_struct_type.values));
            ip.extra.appendSliceAssumeCapacity(@ptrCast([]const u32, anon_struct_type.names));
            return @intToEnum(Index, ip.items.len - 1);
        },

        .union_type => |union_type| {
            ip.items.appendAssumeCapacity(.{
                .tag = switch (union_type.runtime_tag) {
                    .none => .type_union_untagged,
                    .safety => .type_union_safety,
                    .tagged => .type_union_tagged,
                },
                .data = @enumToInt(union_type.index),
            });
        },

        .opaque_type => |opaque_type| {
            ip.items.appendAssumeCapacity(.{
                .tag = .type_opaque,
                .data = try ip.addExtra(gpa, opaque_type),
            });
        },

        .enum_type => |enum_type| {
            assert(enum_type.tag_ty == .noreturn_type or ip.isIntegerType(enum_type.tag_ty));
            for (enum_type.values) |value| assert(ip.typeOf(value) == enum_type.tag_ty);
            assert(enum_type.names_map == .none);
            assert(enum_type.values_map == .none);

            switch (enum_type.tag_mode) {
                .auto => {
                    const names_map = try ip.addMap(gpa);
                    try addStringsToMap(ip, gpa, names_map, enum_type.names);

                    const fields_len = @intCast(u32, enum_type.names.len);
                    try ip.extra.ensureUnusedCapacity(gpa, @typeInfo(EnumAuto).Struct.fields.len +
                        fields_len);
                    ip.items.appendAssumeCapacity(.{
                        .tag = .type_enum_auto,
                        .data = ip.addExtraAssumeCapacity(EnumAuto{
                            .decl = enum_type.decl,
                            .namespace = enum_type.namespace,
                            .int_tag_type = enum_type.tag_ty,
                            .names_map = names_map,
                            .fields_len = fields_len,
                        }),
                    });
                    ip.extra.appendSliceAssumeCapacity(@ptrCast([]const u32, enum_type.names));
                    return @intToEnum(Index, ip.items.len - 1);
                },
                .explicit => return finishGetEnum(ip, gpa, enum_type, .type_enum_explicit),
                .nonexhaustive => return finishGetEnum(ip, gpa, enum_type, .type_enum_nonexhaustive),
            }
        },

        .func_type => |func_type| {
            assert(func_type.return_type != .none);
            for (func_type.param_types) |param_type| assert(param_type != .none);

            const params_len = @intCast(u32, func_type.param_types.len);

            try ip.extra.ensureUnusedCapacity(gpa, @typeInfo(TypeFunction).Struct.fields.len +
                params_len);
            ip.items.appendAssumeCapacity(.{
                .tag = .type_function,
                .data = ip.addExtraAssumeCapacity(TypeFunction{
                    .params_len = params_len,
                    .return_type = func_type.return_type,
                    .comptime_bits = func_type.comptime_bits,
                    .noalias_bits = func_type.noalias_bits,
                    .flags = .{
                        .alignment = func_type.alignment,
                        .cc = func_type.cc,
                        .is_var_args = func_type.is_var_args,
                        .is_generic = func_type.is_generic,
                        .is_noinline = func_type.is_noinline,
                        .align_is_generic = func_type.align_is_generic,
                        .cc_is_generic = func_type.cc_is_generic,
                        .section_is_generic = func_type.section_is_generic,
                        .addrspace_is_generic = func_type.addrspace_is_generic,
                    },
                }),
            });
            ip.extra.appendSliceAssumeCapacity(@ptrCast([]const u32, func_type.param_types));
        },

        .variable => |variable| {
            const has_init = variable.init != .none;
            if (has_init) assert(variable.ty == ip.typeOf(variable.init));
            ip.items.appendAssumeCapacity(.{
                .tag = .variable,
                .data = try ip.addExtra(gpa, Tag.Variable{
                    .ty = variable.ty,
                    .init = variable.init,
                    .decl = variable.decl,
                    .lib_name = variable.lib_name,
                    .flags = .{
                        .is_extern = variable.is_extern,
                        .is_const = variable.is_const,
                        .is_threadlocal = variable.is_threadlocal,
                        .is_weak_linkage = variable.is_weak_linkage,
                    },
                }),
            });
        },

        .extern_func => |extern_func| ip.items.appendAssumeCapacity(.{
            .tag = .extern_func,
            .data = try ip.addExtra(gpa, extern_func),
        }),

        .func => |func| ip.items.appendAssumeCapacity(.{
            .tag = .func,
            .data = try ip.addExtra(gpa, func),
        }),

        .ptr => |ptr| {
            const ptr_type = ip.indexToKey(ptr.ty).ptr_type;
            switch (ptr.len) {
                .none => {
                    assert(ptr_type.size != .Slice);
                    switch (ptr.addr) {
                        .decl => |decl| ip.items.appendAssumeCapacity(.{
                            .tag = .ptr_decl,
                            .data = try ip.addExtra(gpa, PtrDecl{
                                .ty = ptr.ty,
                                .decl = decl,
                            }),
                        }),
                        .mut_decl => |mut_decl| ip.items.appendAssumeCapacity(.{
                            .tag = .ptr_mut_decl,
                            .data = try ip.addExtra(gpa, PtrMutDecl{
                                .ty = ptr.ty,
                                .decl = mut_decl.decl,
                                .runtime_index = mut_decl.runtime_index,
                            }),
                        }),
                        .comptime_field => |field_val| {
                            assert(field_val != .none);
                            ip.items.appendAssumeCapacity(.{
                                .tag = .ptr_comptime_field,
                                .data = try ip.addExtra(gpa, PtrComptimeField{
                                    .ty = ptr.ty,
                                    .field_val = field_val,
                                }),
                            });
                        },
                        .int, .eu_payload, .opt_payload => |base| {
                            switch (ptr.addr) {
                                .int => assert(ip.typeOf(base) == .usize_type),
                                .eu_payload => assert(ip.indexToKey(
                                    ip.indexToKey(ip.typeOf(base)).ptr_type.elem_type,
                                ) == .error_union_type),
                                .opt_payload => assert(ip.indexToKey(
                                    ip.indexToKey(ip.typeOf(base)).ptr_type.elem_type,
                                ) == .opt_type),
                                else => unreachable,
                            }
                            ip.items.appendAssumeCapacity(.{
                                .tag = switch (ptr.addr) {
                                    .int => .ptr_int,
                                    .eu_payload => .ptr_eu_payload,
                                    .opt_payload => .ptr_opt_payload,
                                    else => unreachable,
                                },
                                .data = try ip.addExtra(gpa, PtrBase{
                                    .ty = ptr.ty,
                                    .base = base,
                                }),
                            });
                        },
                        .elem, .field => |base_index| {
                            const base_ptr_type = ip.indexToKey(ip.typeOf(base_index.base)).ptr_type;
                            switch (ptr.addr) {
                                .elem => assert(base_ptr_type.size == .Many),
                                .field => {
                                    assert(base_ptr_type.size == .One);
                                    switch (ip.indexToKey(base_ptr_type.elem_type)) {
                                        .anon_struct_type => |anon_struct_type| {
                                            assert(ptr.addr == .field);
                                            assert(base_index.index < anon_struct_type.types.len);
                                        },
                                        .struct_type => |struct_type| {
                                            assert(ptr.addr == .field);
                                            assert(base_index.index < ip.structPtrUnwrapConst(struct_type.index).?.fields.count());
                                        },
                                        .union_type => |union_type| {
                                            assert(ptr.addr == .field);
                                            assert(base_index.index < ip.unionPtrConst(union_type.index).fields.count());
                                        },
                                        .ptr_type => |slice_type| {
                                            assert(ptr.addr == .field);
                                            assert(slice_type.size == .Slice);
                                            assert(base_index.index < 2);
                                        },
                                        else => unreachable,
                                    }
                                },
                                else => unreachable,
                            }
                            _ = ip.map.pop();
                            const index_index = try ip.get(gpa, .{ .int = .{
                                .ty = .usize_type,
                                .storage = .{ .u64 = base_index.index },
                            } });
                            assert(!(try ip.map.getOrPutAdapted(gpa, key, adapter)).found_existing);
                            try ip.items.ensureUnusedCapacity(gpa, 1);
                            ip.items.appendAssumeCapacity(.{
                                .tag = switch (ptr.addr) {
                                    .elem => .ptr_elem,
                                    .field => .ptr_field,
                                    else => unreachable,
                                },
                                .data = try ip.addExtra(gpa, PtrBaseIndex{
                                    .ty = ptr.ty,
                                    .base = base_index.base,
                                    .index = index_index,
                                }),
                            });
                        },
                    }
                },
                else => {
                    // TODO: change Key.Ptr for slices to reference the manyptr value
                    // rather than having an addr field directly. Then we can avoid
                    // these problematic calls to pop(), get(), and getOrPutAdapted().
                    assert(ptr_type.size == .Slice);
                    _ = ip.map.pop();
                    var new_key = key;
                    new_key.ptr.ty = ip.slicePtrType(ptr.ty);
                    new_key.ptr.len = .none;
                    assert(ip.indexToKey(new_key.ptr.ty).ptr_type.size == .Many);
                    const ptr_index = try ip.get(gpa, new_key);
                    assert(!(try ip.map.getOrPutAdapted(gpa, key, adapter)).found_existing);
                    try ip.items.ensureUnusedCapacity(gpa, 1);
                    ip.items.appendAssumeCapacity(.{
                        .tag = .ptr_slice,
                        .data = try ip.addExtra(gpa, PtrSlice{
                            .ty = ptr.ty,
                            .ptr = ptr_index,
                            .len = ptr.len,
                        }),
                    });
                },
            }
            assert(ptr.ty == ip.indexToKey(@intToEnum(Index, ip.items.len - 1)).ptr.ty);
        },

        .opt => |opt| {
            assert(ip.isOptionalType(opt.ty));
            assert(opt.val == .none or ip.indexToKey(opt.ty).opt_type == ip.typeOf(opt.val));
            ip.items.appendAssumeCapacity(if (opt.val == .none) .{
                .tag = .opt_null,
                .data = @enumToInt(opt.ty),
            } else .{
                .tag = .opt_payload,
                .data = try ip.addExtra(gpa, Tag.TypeValue{
                    .ty = opt.ty,
                    .val = opt.val,
                }),
            });
        },

        .int => |int| b: {
            assert(ip.isIntegerType(int.ty));
            switch (int.storage) {
                .u64, .i64, .big_int => {},
                .lazy_align, .lazy_size => |lazy_ty| {
                    ip.items.appendAssumeCapacity(.{
                        .tag = switch (int.storage) {
                            else => unreachable,
                            .lazy_align => .int_lazy_align,
                            .lazy_size => .int_lazy_size,
                        },
                        .data = try ip.addExtra(gpa, IntLazy{
                            .ty = int.ty,
                            .lazy_ty = lazy_ty,
                        }),
                    });
                    return @intToEnum(Index, ip.items.len - 1);
                },
            }
            switch (int.ty) {
                .u8_type => switch (int.storage) {
                    .big_int => |big_int| {
                        ip.items.appendAssumeCapacity(.{
                            .tag = .int_u8,
                            .data = big_int.to(u8) catch unreachable,
                        });
                        break :b;
                    },
                    inline .u64, .i64 => |x| {
                        ip.items.appendAssumeCapacity(.{
                            .tag = .int_u8,
                            .data = @intCast(u8, x),
                        });
                        break :b;
                    },
                    .lazy_align, .lazy_size => unreachable,
                },
                .u16_type => switch (int.storage) {
                    .big_int => |big_int| {
                        ip.items.appendAssumeCapacity(.{
                            .tag = .int_u16,
                            .data = big_int.to(u16) catch unreachable,
                        });
                        break :b;
                    },
                    inline .u64, .i64 => |x| {
                        ip.items.appendAssumeCapacity(.{
                            .tag = .int_u16,
                            .data = @intCast(u16, x),
                        });
                        break :b;
                    },
                    .lazy_align, .lazy_size => unreachable,
                },
                .u32_type => switch (int.storage) {
                    .big_int => |big_int| {
                        ip.items.appendAssumeCapacity(.{
                            .tag = .int_u32,
                            .data = big_int.to(u32) catch unreachable,
                        });
                        break :b;
                    },
                    inline .u64, .i64 => |x| {
                        ip.items.appendAssumeCapacity(.{
                            .tag = .int_u32,
                            .data = @intCast(u32, x),
                        });
                        break :b;
                    },
                    .lazy_align, .lazy_size => unreachable,
                },
                .i32_type => switch (int.storage) {
                    .big_int => |big_int| {
                        const casted = big_int.to(i32) catch unreachable;
                        ip.items.appendAssumeCapacity(.{
                            .tag = .int_i32,
                            .data = @bitCast(u32, casted),
                        });
                        break :b;
                    },
                    inline .u64, .i64 => |x| {
                        ip.items.appendAssumeCapacity(.{
                            .tag = .int_i32,
                            .data = @bitCast(u32, @intCast(i32, x)),
                        });
                        break :b;
                    },
                    .lazy_align, .lazy_size => unreachable,
                },
                .usize_type => switch (int.storage) {
                    .big_int => |big_int| {
                        if (big_int.to(u32)) |casted| {
                            ip.items.appendAssumeCapacity(.{
                                .tag = .int_usize,
                                .data = casted,
                            });
                            break :b;
                        } else |_| {}
                    },
                    inline .u64, .i64 => |x| {
                        if (std.math.cast(u32, x)) |casted| {
                            ip.items.appendAssumeCapacity(.{
                                .tag = .int_usize,
                                .data = casted,
                            });
                            break :b;
                        }
                    },
                    .lazy_align, .lazy_size => unreachable,
                },
                .comptime_int_type => switch (int.storage) {
                    .big_int => |big_int| {
                        if (big_int.to(u32)) |casted| {
                            ip.items.appendAssumeCapacity(.{
                                .tag = .int_comptime_int_u32,
                                .data = casted,
                            });
                            break :b;
                        } else |_| {}
                        if (big_int.to(i32)) |casted| {
                            ip.items.appendAssumeCapacity(.{
                                .tag = .int_comptime_int_i32,
                                .data = @bitCast(u32, casted),
                            });
                            break :b;
                        } else |_| {}
                    },
                    inline .u64, .i64 => |x| {
                        if (std.math.cast(u32, x)) |casted| {
                            ip.items.appendAssumeCapacity(.{
                                .tag = .int_comptime_int_u32,
                                .data = casted,
                            });
                            break :b;
                        }
                        if (std.math.cast(i32, x)) |casted| {
                            ip.items.appendAssumeCapacity(.{
                                .tag = .int_comptime_int_i32,
                                .data = @bitCast(u32, casted),
                            });
                            break :b;
                        }
                    },
                    .lazy_align, .lazy_size => unreachable,
                },
                else => {},
            }
            switch (int.storage) {
                .big_int => |big_int| {
                    if (big_int.to(u32)) |casted| {
                        ip.items.appendAssumeCapacity(.{
                            .tag = .int_small,
                            .data = try ip.addExtra(gpa, IntSmall{
                                .ty = int.ty,
                                .value = casted,
                            }),
                        });
                        return @intToEnum(Index, ip.items.len - 1);
                    } else |_| {}

                    const tag: Tag = if (big_int.positive) .int_positive else .int_negative;
                    try addInt(ip, gpa, int.ty, tag, big_int.limbs);
                },
                inline .u64, .i64 => |x| {
                    if (std.math.cast(u32, x)) |casted| {
                        ip.items.appendAssumeCapacity(.{
                            .tag = .int_small,
                            .data = try ip.addExtra(gpa, IntSmall{
                                .ty = int.ty,
                                .value = casted,
                            }),
                        });
                        return @intToEnum(Index, ip.items.len - 1);
                    }

                    var buf: [2]Limb = undefined;
                    const big_int = BigIntMutable.init(&buf, x).toConst();
                    const tag: Tag = if (big_int.positive) .int_positive else .int_negative;
                    try addInt(ip, gpa, int.ty, tag, big_int.limbs);
                },
                .lazy_align, .lazy_size => unreachable,
            }
        },

        .err => |err| {
            assert(ip.isErrorSetType(err.ty));
            ip.items.appendAssumeCapacity(.{
                .tag = .error_set_error,
                .data = try ip.addExtra(gpa, err),
            });
        },

        .error_union => |error_union| {
            assert(ip.isErrorUnionType(error_union.ty));
            ip.items.appendAssumeCapacity(switch (error_union.val) {
                .err_name => |err_name| .{
                    .tag = .error_union_error,
                    .data = try ip.addExtra(gpa, Key.Error{
                        .ty = error_union.ty,
                        .name = err_name,
                    }),
                },
                .payload => |payload| .{
                    .tag = .error_union_payload,
                    .data = try ip.addExtra(gpa, Tag.TypeValue{
                        .ty = error_union.ty,
                        .val = payload,
                    }),
                },
            });
        },

        .enum_literal => |enum_literal| ip.items.appendAssumeCapacity(.{
            .tag = .enum_literal,
            .data = @enumToInt(enum_literal),
        }),

        .enum_tag => |enum_tag| {
            assert(ip.isEnumType(enum_tag.ty));
            switch (ip.indexToKey(enum_tag.ty)) {
                .simple_type => assert(ip.isIntegerType(ip.typeOf(enum_tag.int))),
                .enum_type => |enum_type| assert(ip.typeOf(enum_tag.int) == enum_type.tag_ty),
                else => unreachable,
            }
            ip.items.appendAssumeCapacity(.{
                .tag = .enum_tag,
                .data = try ip.addExtra(gpa, enum_tag),
            });
        },

        .float => |float| {
            switch (float.ty) {
                .f16_type => ip.items.appendAssumeCapacity(.{
                    .tag = .float_f16,
                    .data = @bitCast(u16, float.storage.f16),
                }),
                .f32_type => ip.items.appendAssumeCapacity(.{
                    .tag = .float_f32,
                    .data = @bitCast(u32, float.storage.f32),
                }),
                .f64_type => ip.items.appendAssumeCapacity(.{
                    .tag = .float_f64,
                    .data = try ip.addExtra(gpa, Float64.pack(float.storage.f64)),
                }),
                .f80_type => ip.items.appendAssumeCapacity(.{
                    .tag = .float_f80,
                    .data = try ip.addExtra(gpa, Float80.pack(float.storage.f80)),
                }),
                .f128_type => ip.items.appendAssumeCapacity(.{
                    .tag = .float_f128,
                    .data = try ip.addExtra(gpa, Float128.pack(float.storage.f128)),
                }),
                .c_longdouble_type => switch (float.storage) {
                    .f80 => |x| ip.items.appendAssumeCapacity(.{
                        .tag = .float_c_longdouble_f80,
                        .data = try ip.addExtra(gpa, Float80.pack(x)),
                    }),
                    inline .f16, .f32, .f64, .f128 => |x| ip.items.appendAssumeCapacity(.{
                        .tag = .float_c_longdouble_f128,
                        .data = try ip.addExtra(gpa, Float128.pack(x)),
                    }),
                },
                .comptime_float_type => ip.items.appendAssumeCapacity(.{
                    .tag = .float_comptime_float,
                    .data = try ip.addExtra(gpa, Float128.pack(float.storage.f128)),
                }),
                else => unreachable,
            }
        },

        .aggregate => |aggregate| {
            const ty_key = ip.indexToKey(aggregate.ty);
            const len = ip.aggregateTypeLen(aggregate.ty);
            const child = switch (ty_key) {
                .array_type => |array_type| array_type.child,
                .vector_type => |vector_type| vector_type.child,
                .anon_struct_type, .struct_type => .none,
                else => unreachable,
            };
            const sentinel = switch (ty_key) {
                .array_type => |array_type| array_type.sentinel,
                .vector_type, .anon_struct_type, .struct_type => .none,
                else => unreachable,
            };
            const len_including_sentinel = len + @boolToInt(sentinel != .none);
            switch (aggregate.storage) {
                .bytes => |bytes| {
                    assert(child == .u8_type);
                    if (bytes.len != len) {
                        assert(bytes.len == len_including_sentinel);
                        assert(bytes[len] == ip.indexToKey(sentinel).int.storage.u64);
                    }
                },
                .elems => |elems| {
                    if (elems.len != len) {
                        assert(elems.len == len_including_sentinel);
                        assert(elems[len] == sentinel);
                    }
                },
                .repeated_elem => |elem| {
                    assert(sentinel == .none or elem == sentinel);
                },
            }
            switch (ty_key) {
                .array_type, .vector_type => {
                    for (aggregate.storage.values()) |elem| {
                        assert(ip.typeOf(elem) == child);
                    }
                },
                .struct_type => |struct_type| {
                    for (
                        aggregate.storage.values(),
                        ip.structPtrUnwrapConst(struct_type.index).?.fields.values(),
                    ) |elem, field| {
                        assert(ip.typeOf(elem) == field.ty.toIntern());
                    }
                },
                .anon_struct_type => |anon_struct_type| {
                    for (aggregate.storage.values(), anon_struct_type.types) |elem, ty| {
                        assert(ip.typeOf(elem) == ty);
                    }
                },
                else => unreachable,
            }

            if (len == 0) {
                ip.items.appendAssumeCapacity(.{
                    .tag = .only_possible_value,
                    .data = @enumToInt(aggregate.ty),
                });
                return @intToEnum(Index, ip.items.len - 1);
            }

            switch (ty_key) {
                .anon_struct_type => |anon_struct_type| opv: {
                    switch (aggregate.storage) {
                        .bytes => |bytes| for (anon_struct_type.values, bytes) |value, byte| {
                            if (value != ip.getIfExists(.{ .int = .{
                                .ty = .u8_type,
                                .storage = .{ .u64 = byte },
                            } })) break :opv;
                        },
                        .elems => |elems| if (!std.mem.eql(
                            Index,
                            anon_struct_type.values,
                            elems,
                        )) break :opv,
                        .repeated_elem => |elem| for (anon_struct_type.values) |value| {
                            if (value != elem) break :opv;
                        },
                    }
                    // This encoding works thanks to the fact that, as we just verified,
                    // the type itself contains a slice of values that can be provided
                    // in the aggregate fields.
                    ip.items.appendAssumeCapacity(.{
                        .tag = .only_possible_value,
                        .data = @enumToInt(aggregate.ty),
                    });
                    return @intToEnum(Index, ip.items.len - 1);
                },
                else => {},
            }

            repeated: {
                switch (aggregate.storage) {
                    .bytes => |bytes| for (bytes[1..@intCast(usize, len)]) |byte|
                        if (byte != bytes[0]) break :repeated,
                    .elems => |elems| for (elems[1..@intCast(usize, len)]) |elem|
                        if (elem != elems[0]) break :repeated,
                    .repeated_elem => {},
                }
                const elem = switch (aggregate.storage) {
                    .bytes => |bytes| elem: {
                        _ = ip.map.pop();
                        const elem = try ip.get(gpa, .{ .int = .{
                            .ty = .u8_type,
                            .storage = .{ .u64 = bytes[0] },
                        } });
                        assert(!(try ip.map.getOrPutAdapted(gpa, key, adapter)).found_existing);
                        try ip.items.ensureUnusedCapacity(gpa, 1);
                        break :elem elem;
                    },
                    .elems => |elems| elems[0],
                    .repeated_elem => |elem| elem,
                };

                try ip.extra.ensureUnusedCapacity(
                    gpa,
                    @typeInfo(Repeated).Struct.fields.len,
                );
                ip.items.appendAssumeCapacity(.{
                    .tag = .repeated,
                    .data = ip.addExtraAssumeCapacity(Repeated{
                        .ty = aggregate.ty,
                        .elem_val = elem,
                    }),
                });
                return @intToEnum(Index, ip.items.len - 1);
            }

            if (child == .u8_type) bytes: {
                const string_bytes_index = ip.string_bytes.items.len;
                try ip.string_bytes.ensureUnusedCapacity(gpa, len_including_sentinel + 1);
                try ip.extra.ensureUnusedCapacity(gpa, @typeInfo(Bytes).Struct.fields.len);
                switch (aggregate.storage) {
                    .bytes => |bytes| ip.string_bytes.appendSliceAssumeCapacity(bytes),
                    .elems => |elems| for (elems) |elem| switch (ip.indexToKey(elem)) {
                        .undef => {
                            ip.string_bytes.shrinkRetainingCapacity(string_bytes_index);
                            break :bytes;
                        },
                        .int => |int| ip.string_bytes.appendAssumeCapacity(
                            @intCast(u8, int.storage.u64),
                        ),
                        else => unreachable,
                    },
                    .repeated_elem => |elem| switch (ip.indexToKey(elem)) {
                        .undef => break :bytes,
                        .int => |int| @memset(
                            ip.string_bytes.addManyAsSliceAssumeCapacity(len),
                            @intCast(u8, int.storage.u64),
                        ),
                        else => unreachable,
                    },
                }
                if (sentinel != .none) ip.string_bytes.appendAssumeCapacity(
                    @intCast(u8, ip.indexToKey(sentinel).int.storage.u64),
                );
                const bytes = try ip.getOrPutTrailingString(gpa, len_including_sentinel);
                ip.items.appendAssumeCapacity(.{
                    .tag = .bytes,
                    .data = ip.addExtraAssumeCapacity(Bytes{
                        .ty = aggregate.ty,
                        .bytes = bytes.toString(),
                    }),
                });
                return @intToEnum(Index, ip.items.len - 1);
            }

            try ip.extra.ensureUnusedCapacity(
                gpa,
                @typeInfo(Aggregate).Struct.fields.len + len_including_sentinel,
            );
            ip.items.appendAssumeCapacity(.{
                .tag = .aggregate,
                .data = ip.addExtraAssumeCapacity(Aggregate{
                    .ty = aggregate.ty,
                }),
            });
            ip.extra.appendSliceAssumeCapacity(@ptrCast([]const u32, aggregate.storage.elems));
            if (sentinel != .none) ip.extra.appendAssumeCapacity(@enumToInt(sentinel));
        },

        .un => |un| {
            assert(un.ty != .none);
            assert(un.tag != .none);
            assert(un.val != .none);
            ip.items.appendAssumeCapacity(.{
                .tag = .union_value,
                .data = try ip.addExtra(gpa, un),
            });
        },

        .memoized_decl => |memoized_decl| {
            assert(memoized_decl.val != .none);
            ip.items.appendAssumeCapacity(.{
                .tag = .memoized_decl,
                .data = try ip.addExtra(gpa, memoized_decl),
            });
        },

        .memoized_call => |memoized_call| {
            for (memoized_call.arg_values) |arg| assert(arg != .none);
            try ip.extra.ensureUnusedCapacity(gpa, @typeInfo(MemoizedCall).Struct.fields.len +
                memoized_call.arg_values.len);
            ip.items.appendAssumeCapacity(.{
                .tag = .memoized_call,
                .data = ip.addExtraAssumeCapacity(MemoizedCall{
                    .func = memoized_call.func,
                    .args_len = @intCast(u32, memoized_call.arg_values.len),
                    .result = memoized_call.result,
                }),
            });
            ip.extra.appendSliceAssumeCapacity(@ptrCast([]const u32, memoized_call.arg_values));
        },
    }
    return @intToEnum(Index, ip.items.len - 1);
}

/// Provides API for completing an enum type after calling `getIncompleteEnum`.
pub const IncompleteEnumType = struct {
    index: Index,
    tag_ty_index: u32,
    names_map: MapIndex,
    names_start: u32,
    values_map: OptionalMapIndex,
    values_start: u32,

    pub fn setTagType(self: @This(), ip: *InternPool, tag_ty: Index) void {
        assert(tag_ty == .noreturn_type or ip.isIntegerType(tag_ty));
        ip.extra.items[self.tag_ty_index] = @enumToInt(tag_ty);
    }

    /// Returns the already-existing field with the same name, if any.
    pub fn addFieldName(
        self: @This(),
        ip: *InternPool,
        gpa: Allocator,
        name: NullTerminatedString,
    ) Allocator.Error!?u32 {
        const map = &ip.maps.items[@enumToInt(self.names_map)];
        const field_index = map.count();
        const strings = ip.extra.items[self.names_start..][0..field_index];
        const adapter: NullTerminatedString.Adapter = .{
            .strings = @ptrCast([]const NullTerminatedString, strings),
        };
        const gop = try map.getOrPutAdapted(gpa, name, adapter);
        if (gop.found_existing) return @intCast(u32, gop.index);
        ip.extra.items[self.names_start + field_index] = @enumToInt(name);
        return null;
    }

    /// Returns the already-existing field with the same value, if any.
    /// Make sure the type of the value has the integer tag type of the enum.
    pub fn addFieldValue(
        self: @This(),
        ip: *InternPool,
        gpa: Allocator,
        value: Index,
    ) Allocator.Error!?u32 {
        assert(ip.typeOf(value) == @intToEnum(Index, ip.extra.items[self.tag_ty_index]));
        const map = &ip.maps.items[@enumToInt(self.values_map.unwrap().?)];
        const field_index = map.count();
        const indexes = ip.extra.items[self.values_start..][0..field_index];
        const adapter: Index.Adapter = .{
            .indexes = @ptrCast([]const Index, indexes),
        };
        const gop = try map.getOrPutAdapted(gpa, value, adapter);
        if (gop.found_existing) return @intCast(u32, gop.index);
        ip.extra.items[self.values_start + field_index] = @enumToInt(value);
        return null;
    }
};

/// This is used to create an enum type in the `InternPool`, with the ability
/// to update the tag type, field names, and field values later.
pub fn getIncompleteEnum(
    ip: *InternPool,
    gpa: Allocator,
    enum_type: Key.IncompleteEnumType,
) Allocator.Error!IncompleteEnumType {
    switch (enum_type.tag_mode) {
        .auto => return getIncompleteEnumAuto(ip, gpa, enum_type),
        .explicit => return getIncompleteEnumExplicit(ip, gpa, enum_type, .type_enum_explicit),
        .nonexhaustive => return getIncompleteEnumExplicit(ip, gpa, enum_type, .type_enum_nonexhaustive),
    }
}

fn getIncompleteEnumAuto(
    ip: *InternPool,
    gpa: Allocator,
    enum_type: Key.IncompleteEnumType,
) Allocator.Error!IncompleteEnumType {
    const int_tag_type = if (enum_type.tag_ty != .none)
        enum_type.tag_ty
    else
        try ip.get(gpa, .{ .int_type = .{
            .bits = if (enum_type.fields_len == 0) 0 else std.math.log2_int_ceil(u32, enum_type.fields_len),
            .signedness = .unsigned,
        } });

    // We must keep the map in sync with `items`. The hash and equality functions
    // for enum types only look at the decl field, which is present even in
    // an `IncompleteEnumType`.
    const adapter: KeyAdapter = .{ .intern_pool = ip };
    const gop = try ip.map.getOrPutAdapted(gpa, enum_type.toKey(), adapter);
    assert(!gop.found_existing);

    const names_map = try ip.addMap(gpa);

    const extra_fields_len: u32 = @typeInfo(EnumAuto).Struct.fields.len;
    try ip.extra.ensureUnusedCapacity(gpa, extra_fields_len + enum_type.fields_len);
    try ip.items.ensureUnusedCapacity(gpa, 1);

    const extra_index = ip.addExtraAssumeCapacity(EnumAuto{
        .decl = enum_type.decl,
        .namespace = enum_type.namespace,
        .int_tag_type = int_tag_type,
        .names_map = names_map,
        .fields_len = enum_type.fields_len,
    });

    ip.items.appendAssumeCapacity(.{
        .tag = .type_enum_auto,
        .data = extra_index,
    });
    ip.extra.appendNTimesAssumeCapacity(@enumToInt(Index.none), enum_type.fields_len);
    return .{
        .index = @intToEnum(Index, ip.items.len - 1),
        .tag_ty_index = extra_index + std.meta.fieldIndex(EnumAuto, "int_tag_type").?,
        .names_map = names_map,
        .names_start = extra_index + extra_fields_len,
        .values_map = .none,
        .values_start = undefined,
    };
}

fn getIncompleteEnumExplicit(
    ip: *InternPool,
    gpa: Allocator,
    enum_type: Key.IncompleteEnumType,
    tag: Tag,
) Allocator.Error!IncompleteEnumType {
    // We must keep the map in sync with `items`. The hash and equality functions
    // for enum types only look at the decl field, which is present even in
    // an `IncompleteEnumType`.
    const adapter: KeyAdapter = .{ .intern_pool = ip };
    const gop = try ip.map.getOrPutAdapted(gpa, enum_type.toKey(), adapter);
    assert(!gop.found_existing);

    const names_map = try ip.addMap(gpa);
    const values_map: OptionalMapIndex = if (!enum_type.has_values) .none else m: {
        const values_map = try ip.addMap(gpa);
        break :m values_map.toOptional();
    };

    const reserved_len = enum_type.fields_len +
        if (enum_type.has_values) enum_type.fields_len else 0;

    const extra_fields_len: u32 = @typeInfo(EnumExplicit).Struct.fields.len;
    try ip.extra.ensureUnusedCapacity(gpa, extra_fields_len + reserved_len);
    try ip.items.ensureUnusedCapacity(gpa, 1);

    const extra_index = ip.addExtraAssumeCapacity(EnumExplicit{
        .decl = enum_type.decl,
        .namespace = enum_type.namespace,
        .int_tag_type = enum_type.tag_ty,
        .fields_len = enum_type.fields_len,
        .names_map = names_map,
        .values_map = values_map,
    });

    ip.items.appendAssumeCapacity(.{
        .tag = tag,
        .data = extra_index,
    });
    // This is both fields and values (if present).
    ip.extra.appendNTimesAssumeCapacity(@enumToInt(Index.none), reserved_len);
    return .{
        .index = @intToEnum(Index, ip.items.len - 1),
        .tag_ty_index = extra_index + std.meta.fieldIndex(EnumExplicit, "int_tag_type").?,
        .names_map = names_map,
        .names_start = extra_index + extra_fields_len,
        .values_map = values_map,
        .values_start = extra_index + extra_fields_len + enum_type.fields_len,
    };
}

pub fn finishGetEnum(
    ip: *InternPool,
    gpa: Allocator,
    enum_type: Key.EnumType,
    tag: Tag,
) Allocator.Error!Index {
    const names_map = try ip.addMap(gpa);
    try addStringsToMap(ip, gpa, names_map, enum_type.names);

    const values_map: OptionalMapIndex = if (enum_type.values.len == 0) .none else m: {
        const values_map = try ip.addMap(gpa);
        try addIndexesToMap(ip, gpa, values_map, enum_type.values);
        break :m values_map.toOptional();
    };
    const fields_len = @intCast(u32, enum_type.names.len);
    try ip.extra.ensureUnusedCapacity(gpa, @typeInfo(EnumExplicit).Struct.fields.len +
        fields_len);
    ip.items.appendAssumeCapacity(.{
        .tag = tag,
        .data = ip.addExtraAssumeCapacity(EnumExplicit{
            .decl = enum_type.decl,
            .namespace = enum_type.namespace,
            .int_tag_type = enum_type.tag_ty,
            .fields_len = fields_len,
            .names_map = names_map,
            .values_map = values_map,
        }),
    });
    ip.extra.appendSliceAssumeCapacity(@ptrCast([]const u32, enum_type.names));
    ip.extra.appendSliceAssumeCapacity(@ptrCast([]const u32, enum_type.values));
    return @intToEnum(Index, ip.items.len - 1);
}

pub fn getIfExists(ip: *const InternPool, key: Key) ?Index {
    const adapter: KeyAdapter = .{ .intern_pool = ip };
    const index = ip.map.getIndexAdapted(key, adapter) orelse return null;
    return @intToEnum(Index, index);
}

pub fn getAssumeExists(ip: *const InternPool, key: Key) Index {
    return ip.getIfExists(key).?;
}

fn addStringsToMap(
    ip: *InternPool,
    gpa: Allocator,
    map_index: MapIndex,
    strings: []const NullTerminatedString,
) Allocator.Error!void {
    const map = &ip.maps.items[@enumToInt(map_index)];
    const adapter: NullTerminatedString.Adapter = .{ .strings = strings };
    for (strings) |string| {
        const gop = try map.getOrPutAdapted(gpa, string, adapter);
        assert(!gop.found_existing);
    }
}

fn addIndexesToMap(
    ip: *InternPool,
    gpa: Allocator,
    map_index: MapIndex,
    indexes: []const Index,
) Allocator.Error!void {
    const map = &ip.maps.items[@enumToInt(map_index)];
    const adapter: Index.Adapter = .{ .indexes = indexes };
    for (indexes) |index| {
        const gop = try map.getOrPutAdapted(gpa, index, adapter);
        assert(!gop.found_existing);
    }
}

fn addMap(ip: *InternPool, gpa: Allocator) Allocator.Error!MapIndex {
    const ptr = try ip.maps.addOne(gpa);
    ptr.* = .{};
    return @intToEnum(MapIndex, ip.maps.items.len - 1);
}

/// This operation only happens under compile error conditions.
/// Leak the index until the next garbage collection.
pub fn remove(ip: *InternPool, index: Index) void {
    _ = ip;
    _ = index;
    @setCold(true);
    @panic("TODO this is a bit problematic to implement, could we maybe just never support a remove() operation on InternPool?");
}

fn addInt(ip: *InternPool, gpa: Allocator, ty: Index, tag: Tag, limbs: []const Limb) !void {
    const limbs_len = @intCast(u32, limbs.len);
    try ip.reserveLimbs(gpa, @typeInfo(Int).Struct.fields.len + limbs_len);
    ip.items.appendAssumeCapacity(.{
        .tag = tag,
        .data = ip.addLimbsExtraAssumeCapacity(Int{
            .ty = ty,
            .limbs_len = limbs_len,
        }),
    });
    ip.addLimbsAssumeCapacity(limbs);
}

fn addExtra(ip: *InternPool, gpa: Allocator, extra: anytype) Allocator.Error!u32 {
    const fields = @typeInfo(@TypeOf(extra)).Struct.fields;
    try ip.extra.ensureUnusedCapacity(gpa, fields.len);
    return ip.addExtraAssumeCapacity(extra);
}

fn addExtraAssumeCapacity(ip: *InternPool, extra: anytype) u32 {
    const result = @intCast(u32, ip.extra.items.len);
    inline for (@typeInfo(@TypeOf(extra)).Struct.fields) |field| {
        ip.extra.appendAssumeCapacity(switch (field.type) {
            u32 => @field(extra, field.name),
            Index => @enumToInt(@field(extra, field.name)),
            Module.Decl.Index => @enumToInt(@field(extra, field.name)),
            Module.Namespace.Index => @enumToInt(@field(extra, field.name)),
            Module.Namespace.OptionalIndex => @enumToInt(@field(extra, field.name)),
            Module.Fn.Index => @enumToInt(@field(extra, field.name)),
            MapIndex => @enumToInt(@field(extra, field.name)),
            OptionalMapIndex => @enumToInt(@field(extra, field.name)),
            RuntimeIndex => @enumToInt(@field(extra, field.name)),
            String => @enumToInt(@field(extra, field.name)),
            NullTerminatedString => @enumToInt(@field(extra, field.name)),
            OptionalNullTerminatedString => @enumToInt(@field(extra, field.name)),
            i32 => @bitCast(u32, @field(extra, field.name)),
            Pointer.Flags => @bitCast(u32, @field(extra, field.name)),
            TypeFunction.Flags => @bitCast(u32, @field(extra, field.name)),
            Pointer.PackedOffset => @bitCast(u32, @field(extra, field.name)),
            Pointer.VectorIndex => @enumToInt(@field(extra, field.name)),
            Tag.Variable.Flags => @bitCast(u32, @field(extra, field.name)),
            else => @compileError("bad field type: " ++ @typeName(field.type)),
        });
    }
    return result;
}

fn reserveLimbs(ip: *InternPool, gpa: Allocator, n: usize) !void {
    switch (@sizeOf(Limb)) {
        @sizeOf(u32) => try ip.extra.ensureUnusedCapacity(gpa, n),
        @sizeOf(u64) => try ip.limbs.ensureUnusedCapacity(gpa, n),
        else => @compileError("unsupported host"),
    }
}

fn addLimbsExtraAssumeCapacity(ip: *InternPool, extra: anytype) u32 {
    switch (@sizeOf(Limb)) {
        @sizeOf(u32) => return addExtraAssumeCapacity(ip, extra),
        @sizeOf(u64) => {},
        else => @compileError("unsupported host"),
    }
    const result = @intCast(u32, ip.limbs.items.len);
    inline for (@typeInfo(@TypeOf(extra)).Struct.fields, 0..) |field, i| {
        const new: u32 = switch (field.type) {
            u32 => @field(extra, field.name),
            Index => @enumToInt(@field(extra, field.name)),
            else => @compileError("bad field type: " ++ @typeName(field.type)),
        };
        if (i % 2 == 0) {
            ip.limbs.appendAssumeCapacity(new);
        } else {
            ip.limbs.items[ip.limbs.items.len - 1] |= @as(u64, new) << 32;
        }
    }
    return result;
}

fn addLimbsAssumeCapacity(ip: *InternPool, limbs: []const Limb) void {
    switch (@sizeOf(Limb)) {
        @sizeOf(u32) => ip.extra.appendSliceAssumeCapacity(limbs),
        @sizeOf(u64) => ip.limbs.appendSliceAssumeCapacity(limbs),
        else => @compileError("unsupported host"),
    }
}

fn extraDataTrail(ip: *const InternPool, comptime T: type, index: usize) struct { data: T, end: usize } {
    var result: T = undefined;
    const fields = @typeInfo(T).Struct.fields;
    inline for (fields, 0..) |field, i| {
        const int32 = ip.extra.items[i + index];
        @field(result, field.name) = switch (field.type) {
            u32 => int32,
            Index => @intToEnum(Index, int32),
            Module.Decl.Index => @intToEnum(Module.Decl.Index, int32),
            Module.Namespace.Index => @intToEnum(Module.Namespace.Index, int32),
            Module.Namespace.OptionalIndex => @intToEnum(Module.Namespace.OptionalIndex, int32),
            Module.Fn.Index => @intToEnum(Module.Fn.Index, int32),
            MapIndex => @intToEnum(MapIndex, int32),
            OptionalMapIndex => @intToEnum(OptionalMapIndex, int32),
            RuntimeIndex => @intToEnum(RuntimeIndex, int32),
            String => @intToEnum(String, int32),
            NullTerminatedString => @intToEnum(NullTerminatedString, int32),
            OptionalNullTerminatedString => @intToEnum(OptionalNullTerminatedString, int32),
            i32 => @bitCast(i32, int32),
            Pointer.Flags => @bitCast(Pointer.Flags, int32),
            TypeFunction.Flags => @bitCast(TypeFunction.Flags, int32),
            Pointer.PackedOffset => @bitCast(Pointer.PackedOffset, int32),
            Pointer.VectorIndex => @intToEnum(Pointer.VectorIndex, int32),
            Tag.Variable.Flags => @bitCast(Tag.Variable.Flags, int32),
            else => @compileError("bad field type: " ++ @typeName(field.type)),
        };
    }
    return .{
        .data = result,
        .end = index + fields.len,
    };
}

fn extraData(ip: *const InternPool, comptime T: type, index: usize) T {
    return extraDataTrail(ip, T, index).data;
}

/// Asserts the struct has 32-bit fields and the number of fields is evenly divisible by 2.
fn limbData(ip: *const InternPool, comptime T: type, index: usize) T {
    switch (@sizeOf(Limb)) {
        @sizeOf(u32) => return extraData(ip, T, index),
        @sizeOf(u64) => {},
        else => @compileError("unsupported host"),
    }
    var result: T = undefined;
    inline for (@typeInfo(T).Struct.fields, 0..) |field, i| {
        const host_int = ip.limbs.items[index + i / 2];
        const int32 = if (i % 2 == 0)
            @truncate(u32, host_int)
        else
            @truncate(u32, host_int >> 32);

        @field(result, field.name) = switch (field.type) {
            u32 => int32,
            Index => @intToEnum(Index, int32),
            else => @compileError("bad field type: " ++ @typeName(field.type)),
        };
    }
    return result;
}

/// This function returns the Limb slice that is trailing data after a payload.
fn limbSlice(ip: *const InternPool, comptime S: type, limb_index: u32, len: u32) []const Limb {
    const field_count = @typeInfo(S).Struct.fields.len;
    switch (@sizeOf(Limb)) {
        @sizeOf(u32) => {
            const start = limb_index + field_count;
            return ip.extra.items[start..][0..len];
        },
        @sizeOf(u64) => {
            const start = limb_index + @divExact(field_count, 2);
            return ip.limbs.items[start..][0..len];
        },
        else => @compileError("unsupported host"),
    }
}

const LimbsAsIndexes = struct {
    start: u32,
    len: u32,
};

fn limbsSliceToIndex(ip: *const InternPool, limbs: []const Limb) LimbsAsIndexes {
    const host_slice = switch (@sizeOf(Limb)) {
        @sizeOf(u32) => ip.extra.items,
        @sizeOf(u64) => ip.limbs.items,
        else => @compileError("unsupported host"),
    };
    // TODO: https://github.com/ziglang/zig/issues/1738
    return .{
        .start = @intCast(u32, @divExact(@ptrToInt(limbs.ptr) - @ptrToInt(host_slice.ptr), @sizeOf(Limb))),
        .len = @intCast(u32, limbs.len),
    };
}

/// This function converts Limb array indexes to a primitive slice type.
fn limbsIndexToSlice(ip: *const InternPool, limbs: LimbsAsIndexes) []const Limb {
    return switch (@sizeOf(Limb)) {
        @sizeOf(u32) => ip.extra.items[limbs.start..][0..limbs.len],
        @sizeOf(u64) => ip.limbs.items[limbs.start..][0..limbs.len],
        else => @compileError("unsupported host"),
    };
}

test "basic usage" {
    const gpa = std.testing.allocator;

    var ip: InternPool = .{};
    defer ip.deinit(gpa);

    const i32_type = try ip.get(gpa, .{ .int_type = .{
        .signedness = .signed,
        .bits = 32,
    } });
    const array_i32 = try ip.get(gpa, .{ .array_type = .{
        .len = 10,
        .child = i32_type,
        .sentinel = .none,
    } });

    const another_i32_type = try ip.get(gpa, .{ .int_type = .{
        .signedness = .signed,
        .bits = 32,
    } });
    try std.testing.expect(another_i32_type == i32_type);

    const another_array_i32 = try ip.get(gpa, .{ .array_type = .{
        .len = 10,
        .child = i32_type,
        .sentinel = .none,
    } });
    try std.testing.expect(another_array_i32 == array_i32);
}

pub fn childType(ip: *const InternPool, i: Index) Index {
    return switch (ip.indexToKey(i)) {
        .ptr_type => |ptr_type| ptr_type.elem_type,
        .vector_type => |vector_type| vector_type.child,
        .array_type => |array_type| array_type.child,
        .opt_type, .anyframe_type => |child| child,
        else => unreachable,
    };
}

/// Given a slice type, returns the type of the ptr field.
pub fn slicePtrType(ip: *const InternPool, i: Index) Index {
    switch (i) {
        .slice_const_u8_type => return .manyptr_const_u8_type,
        .slice_const_u8_sentinel_0_type => return .manyptr_const_u8_sentinel_0_type,
        else => {},
    }
    const item = ip.items.get(@enumToInt(i));
    switch (item.tag) {
        .type_slice => return @intToEnum(Index, item.data),
        else => unreachable, // not a slice type
    }
}

/// Given a slice value, returns the value of the ptr field.
pub fn slicePtr(ip: *const InternPool, i: Index) Index {
    const item = ip.items.get(@enumToInt(i));
    switch (item.tag) {
        .ptr_slice => return ip.extraData(PtrSlice, item.data).ptr,
        else => unreachable, // not a slice value
    }
}

/// Given a slice value, returns the value of the len field.
pub fn sliceLen(ip: *const InternPool, i: Index) Index {
    const item = ip.items.get(@enumToInt(i));
    switch (item.tag) {
        .ptr_slice => return ip.extraData(PtrSlice, item.data).len,
        else => unreachable, // not a slice value
    }
}

/// Given an existing value, returns the same value but with the supplied type.
/// Only some combinations are allowed:
/// * identity coercion
/// * undef => any
/// * int <=> int
/// * int <=> enum
/// * enum_literal => enum
/// * ptr <=> ptr
/// * opt ptr <=> ptr
/// * opt ptr <=> opt ptr
/// * int <=> ptr
/// * null_value => opt
/// * payload => opt
/// * error set <=> error set
/// * error union <=> error union
/// * error set => error union
/// * payload => error union
/// * fn <=> fn
pub fn getCoerced(ip: *InternPool, gpa: Allocator, val: Index, new_ty: Index) Allocator.Error!Index {
    const old_ty = ip.typeOf(val);
    if (old_ty == new_ty) return val;
    switch (val) {
        .undef => return ip.get(gpa, .{ .undef = new_ty }),
        .null_value => if (ip.isOptionalType(new_ty))
            return ip.get(gpa, .{ .opt = .{
                .ty = new_ty,
                .val = .none,
            } })
        else if (ip.isPointerType(new_ty))
            return ip.get(gpa, .{ .ptr = .{
                .ty = new_ty,
                .addr = .{ .int = .zero_usize },
                .len = switch (ip.indexToKey(new_ty).ptr_type.size) {
                    .One, .Many, .C => .none,
                    .Slice => try ip.get(gpa, .{ .undef = .usize_type }),
                },
            } }),
        else => switch (ip.indexToKey(val)) {
            .undef => return ip.get(gpa, .{ .undef = new_ty }),
            .extern_func => |extern_func| if (ip.isFunctionType(new_ty))
                return ip.get(gpa, .{ .extern_func = .{
                    .ty = new_ty,
                    .decl = extern_func.decl,
                    .lib_name = extern_func.lib_name,
                } }),
            .func => |func| if (ip.isFunctionType(new_ty))
                return ip.get(gpa, .{ .func = .{
                    .ty = new_ty,
                    .index = func.index,
                } }),
            .int => |int| switch (ip.indexToKey(new_ty)) {
                .enum_type => |enum_type| return ip.get(gpa, .{ .enum_tag = .{
                    .ty = new_ty,
                    .int = try ip.getCoerced(gpa, val, enum_type.tag_ty),
                } }),
                .ptr_type => return ip.get(gpa, .{ .ptr = .{
                    .ty = new_ty,
                    .addr = .{ .int = try ip.getCoerced(gpa, val, .usize_type) },
                } }),
                else => if (ip.isIntegerType(new_ty))
                    return getCoercedInts(ip, gpa, int, new_ty),
            },
            .enum_tag => |enum_tag| if (ip.isIntegerType(new_ty))
                return getCoercedInts(ip, gpa, ip.indexToKey(enum_tag.int).int, new_ty),
            .enum_literal => |enum_literal| switch (ip.indexToKey(new_ty)) {
                .enum_type => |enum_type| {
                    const index = enum_type.nameIndex(ip, enum_literal).?;
                    return ip.get(gpa, .{ .enum_tag = .{
                        .ty = new_ty,
                        .int = if (enum_type.values.len != 0)
                            enum_type.values[index]
                        else
                            try ip.get(gpa, .{ .int = .{
                                .ty = enum_type.tag_ty,
                                .storage = .{ .u64 = index },
                            } }),
                    } });
                },
                else => {},
            },
            .ptr => |ptr| if (ip.isPointerType(new_ty))
                return ip.get(gpa, .{ .ptr = .{
                    .ty = new_ty,
                    .addr = ptr.addr,
                    .len = ptr.len,
                } })
            else if (ip.isIntegerType(new_ty))
                switch (ptr.addr) {
                    .int => |int| return ip.getCoerced(gpa, int, new_ty),
                    else => {},
                },
            .opt => |opt| if (ip.isPointerType(new_ty))
                return switch (opt.val) {
                    .none => try ip.get(gpa, .{ .ptr = .{
                        .ty = new_ty,
                        .addr = .{ .int = .zero_usize },
                        .len = switch (ip.indexToKey(new_ty).ptr_type.size) {
                            .One, .Many, .C => .none,
                            .Slice => try ip.get(gpa, .{ .undef = .usize_type }),
                        },
                    } }),
                    else => |payload| try ip.getCoerced(gpa, payload, new_ty),
                },
            .err => |err| if (ip.isErrorSetType(new_ty))
                return ip.get(gpa, .{ .err = .{
                    .ty = new_ty,
                    .name = err.name,
                } })
            else if (ip.isErrorUnionType(new_ty))
                return ip.get(gpa, .{ .error_union = .{
                    .ty = new_ty,
                    .val = .{ .err_name = err.name },
                } }),
            .error_union => |error_union| if (ip.isErrorUnionType(new_ty))
                return ip.get(gpa, .{ .error_union = .{
                    .ty = new_ty,
                    .val = error_union.val,
                } }),
            else => {},
        },
    }
    switch (ip.indexToKey(new_ty)) {
        .opt_type => |child_type| switch (val) {
            .null_value => return ip.get(gpa, .{ .opt = .{
                .ty = new_ty,
                .val = .none,
            } }),
            else => return ip.get(gpa, .{ .opt = .{
                .ty = new_ty,
                .val = try ip.getCoerced(gpa, val, child_type),
            } }),
        },
        .error_union_type => |error_union_type| return ip.get(gpa, .{ .error_union = .{
            .ty = new_ty,
            .val = .{ .payload = try ip.getCoerced(gpa, val, error_union_type.payload_type) },
        } }),
        else => {},
    }
    if (std.debug.runtime_safety) {
        std.debug.panic("InternPool.getCoerced of {s} not implemented from {s} to {s}", .{
            @tagName(ip.indexToKey(val)),
            @tagName(ip.indexToKey(old_ty)),
            @tagName(ip.indexToKey(new_ty)),
        });
    }
    unreachable;
}

/// Asserts `val` has an integer type.
/// Assumes `new_ty` is an integer type.
pub fn getCoercedInts(ip: *InternPool, gpa: Allocator, int: Key.Int, new_ty: Index) Allocator.Error!Index {
    // The key cannot be passed directly to `get`, otherwise in the case of
    // big_int storage, the limbs would be invalidated before they are read.
    // Here we pre-reserve the limbs to ensure that the logic in `addInt` will
    // not use an invalidated limbs pointer.
    const new_storage: Key.Int.Storage = switch (int.storage) {
        .u64, .i64, .lazy_align, .lazy_size => int.storage,
        .big_int => |big_int| storage: {
            const positive = big_int.positive;
            const limbs = ip.limbsSliceToIndex(big_int.limbs);
            // This line invalidates the limbs slice, but the indexes computed in the
            // previous line are still correct.
            try reserveLimbs(ip, gpa, @typeInfo(Int).Struct.fields.len + big_int.limbs.len);
            break :storage .{ .big_int = .{
                .limbs = ip.limbsIndexToSlice(limbs),
                .positive = positive,
            } };
        },
    };
    return ip.get(gpa, .{ .int = .{
        .ty = new_ty,
        .storage = new_storage,
    } });
}

pub fn indexToStructType(ip: *const InternPool, val: Index) Module.Struct.OptionalIndex {
    assert(val != .none);
    const tags = ip.items.items(.tag);
    if (tags[@enumToInt(val)] != .type_struct) return .none;
    const datas = ip.items.items(.data);
    return @intToEnum(Module.Struct.Index, datas[@enumToInt(val)]).toOptional();
}

pub fn indexToUnionType(ip: *const InternPool, val: Index) Module.Union.OptionalIndex {
    assert(val != .none);
    const tags = ip.items.items(.tag);
    switch (tags[@enumToInt(val)]) {
        .type_union_tagged, .type_union_untagged, .type_union_safety => {},
        else => return .none,
    }
    const datas = ip.items.items(.data);
    return @intToEnum(Module.Union.Index, datas[@enumToInt(val)]).toOptional();
}

pub fn indexToFuncType(ip: *const InternPool, val: Index) ?Key.FuncType {
    assert(val != .none);
    const tags = ip.items.items(.tag);
    const datas = ip.items.items(.data);
    switch (tags[@enumToInt(val)]) {
        .type_function => return indexToKeyFuncType(ip, datas[@enumToInt(val)]),
        else => return null,
    }
}

pub fn indexToFunc(ip: *const InternPool, val: Index) Module.Fn.OptionalIndex {
    assert(val != .none);
    const tags = ip.items.items(.tag);
    if (tags[@enumToInt(val)] != .func) return .none;
    const datas = ip.items.items(.data);
    return ip.extraData(Key.Func, datas[@enumToInt(val)]).index.toOptional();
}

pub fn indexToInferredErrorSetType(ip: *const InternPool, val: Index) Module.Fn.InferredErrorSet.OptionalIndex {
    assert(val != .none);
    const tags = ip.items.items(.tag);
    if (tags[@enumToInt(val)] != .type_inferred_error_set) return .none;
    const datas = ip.items.items(.data);
    return @intToEnum(Module.Fn.InferredErrorSet.Index, datas[@enumToInt(val)]).toOptional();
}

/// includes .comptime_int_type
pub fn isIntegerType(ip: *const InternPool, ty: Index) bool {
    return switch (ty) {
        .usize_type,
        .isize_type,
        .c_char_type,
        .c_short_type,
        .c_ushort_type,
        .c_int_type,
        .c_uint_type,
        .c_long_type,
        .c_ulong_type,
        .c_longlong_type,
        .c_ulonglong_type,
        .c_longdouble_type,
        .comptime_int_type,
        => true,
        else => ip.indexToKey(ty) == .int_type,
    };
}

/// does not include .enum_literal_type
pub fn isEnumType(ip: *const InternPool, ty: Index) bool {
    return switch (ty) {
        .atomic_order_type,
        .atomic_rmw_op_type,
        .calling_convention_type,
        .address_space_type,
        .float_mode_type,
        .reduce_op_type,
        .call_modifier_type,
        => true,
        else => ip.indexToKey(ty) == .enum_type,
    };
}

pub fn isFunctionType(ip: *const InternPool, ty: Index) bool {
    return ip.indexToKey(ty) == .func_type;
}

pub fn isPointerType(ip: *const InternPool, ty: Index) bool {
    return ip.indexToKey(ty) == .ptr_type;
}

pub fn isOptionalType(ip: *const InternPool, ty: Index) bool {
    return ip.indexToKey(ty) == .opt_type;
}

/// includes .inferred_error_set_type
pub fn isErrorSetType(ip: *const InternPool, ty: Index) bool {
    return ty == .anyerror_type or switch (ip.indexToKey(ty)) {
        .error_set_type, .inferred_error_set_type => true,
        else => false,
    };
}

pub fn isInferredErrorSetType(ip: *const InternPool, ty: Index) bool {
    return ip.indexToKey(ty) == .inferred_error_set_type;
}

pub fn isErrorUnionType(ip: *const InternPool, ty: Index) bool {
    return ip.indexToKey(ty) == .error_union_type;
}

pub fn isAggregateType(ip: *const InternPool, ty: Index) bool {
    return switch (ip.indexToKey(ty)) {
        .array_type, .vector_type, .anon_struct_type, .struct_type => true,
        else => false,
    };
}

/// The is only legal because the initializer is not part of the hash.
pub fn mutateVarInit(ip: *InternPool, index: Index, init_index: Index) void {
    assert(ip.items.items(.tag)[@enumToInt(index)] == .variable);
    const field_index = inline for (@typeInfo(Tag.Variable).Struct.fields, 0..) |field, field_index| {
        if (comptime std.mem.eql(u8, field.name, "init")) break field_index;
    } else unreachable;
    ip.extra.items[ip.items.items(.data)[@enumToInt(index)] + field_index] = @enumToInt(init_index);
}

pub fn dump(ip: *const InternPool) void {
    dumpFallible(ip, std.heap.page_allocator) catch return;
}

fn dumpFallible(ip: *const InternPool, arena: Allocator) anyerror!void {
    const items_size = (1 + 4) * ip.items.len;
    const extra_size = 4 * ip.extra.items.len;
    const limbs_size = 8 * ip.limbs.items.len;
    // TODO: fields size is not taken into account
    const structs_size = ip.allocated_structs.len *
        (@sizeOf(Module.Struct) + @sizeOf(Module.Namespace) + @sizeOf(Module.Decl));
    const unions_size = ip.allocated_unions.len *
        (@sizeOf(Module.Union) + @sizeOf(Module.Namespace) + @sizeOf(Module.Decl));
    const funcs_size = ip.allocated_funcs.len *
        (@sizeOf(Module.Fn) + @sizeOf(Module.Decl));

    // TODO: map overhead size is not taken into account
    const total_size = @sizeOf(InternPool) + items_size + extra_size + limbs_size +
        structs_size + unions_size + funcs_size;

    std.debug.print(
        \\InternPool size: {d} bytes
        \\  {d} items: {d} bytes
        \\  {d} extra: {d} bytes
        \\  {d} limbs: {d} bytes
        \\  {d} structs: {d} bytes
        \\  {d} unions: {d} bytes
        \\  {d} funcs: {d} bytes
        \\
    , .{
        total_size,
        ip.items.len,
        items_size,
        ip.extra.items.len,
        extra_size,
        ip.limbs.items.len,
        limbs_size,
        ip.allocated_structs.len,
        structs_size,
        ip.allocated_unions.len,
        unions_size,
        ip.allocated_funcs.len,
        funcs_size,
    });

    const tags = ip.items.items(.tag);
    const datas = ip.items.items(.data);
    const TagStats = struct {
        count: usize = 0,
        bytes: usize = 0,
    };
    var counts = std.AutoArrayHashMap(Tag, TagStats).init(arena);
    for (tags, datas) |tag, data| {
        const gop = try counts.getOrPut(tag);
        if (!gop.found_existing) gop.value_ptr.* = .{};
        gop.value_ptr.count += 1;
        gop.value_ptr.bytes += 1 + 4 + @as(usize, switch (tag) {
            .type_int_signed => 0,
            .type_int_unsigned => 0,
            .type_array_small => @sizeOf(Vector),
            .type_array_big => @sizeOf(Array),
            .type_vector => @sizeOf(Vector),
            .type_pointer => @sizeOf(Pointer),
            .type_slice => 0,
            .type_optional => 0,
            .type_anyframe => 0,
            .type_error_union => @sizeOf(Key.ErrorUnionType),
            .type_error_set => b: {
                const info = ip.extraData(ErrorSet, data);
                break :b @sizeOf(ErrorSet) + (@sizeOf(u32) * info.names_len);
            },
            .type_inferred_error_set => @sizeOf(Module.Fn.InferredErrorSet),
            .type_enum_explicit, .type_enum_nonexhaustive => @sizeOf(EnumExplicit),
            .type_enum_auto => @sizeOf(EnumAuto),
            .type_opaque => @sizeOf(Key.OpaqueType),
            .type_struct => b: {
                const struct_index = @intToEnum(Module.Struct.Index, data);
                const struct_obj = ip.structPtrConst(struct_index);
                break :b @sizeOf(Module.Struct) +
                    @sizeOf(Module.Namespace) +
                    @sizeOf(Module.Decl) +
                    (struct_obj.fields.count() * @sizeOf(Module.Struct.Field));
            },
            .type_struct_ns => @sizeOf(Module.Namespace),
            .type_struct_anon => b: {
                const info = ip.extraData(TypeStructAnon, data);
                break :b @sizeOf(TypeStructAnon) + (@sizeOf(u32) * 3 * info.fields_len);
            },
            .type_tuple_anon => b: {
                const info = ip.extraData(TypeStructAnon, data);
                break :b @sizeOf(TypeStructAnon) + (@sizeOf(u32) * 2 * info.fields_len);
            },

            .type_union_tagged,
            .type_union_untagged,
            .type_union_safety,
            => @sizeOf(Module.Union) + @sizeOf(Module.Namespace) + @sizeOf(Module.Decl),

            .type_function => b: {
                const info = ip.extraData(TypeFunction, data);
                break :b @sizeOf(TypeFunction) + (@sizeOf(Index) * info.params_len);
            },

            .undef => 0,
            .runtime_value => @sizeOf(Tag.TypeValue),
            .simple_type => 0,
            .simple_value => 0,
            .ptr_decl => @sizeOf(PtrDecl),
            .ptr_mut_decl => @sizeOf(PtrMutDecl),
            .ptr_comptime_field => @sizeOf(PtrComptimeField),
            .ptr_int => @sizeOf(PtrBase),
            .ptr_eu_payload => @sizeOf(PtrBase),
            .ptr_opt_payload => @sizeOf(PtrBase),
            .ptr_elem => @sizeOf(PtrBaseIndex),
            .ptr_field => @sizeOf(PtrBaseIndex),
            .ptr_slice => @sizeOf(PtrSlice),
            .opt_null => 0,
            .opt_payload => @sizeOf(Tag.TypeValue),
            .int_u8 => 0,
            .int_u16 => 0,
            .int_u32 => 0,
            .int_i32 => 0,
            .int_usize => 0,
            .int_comptime_int_u32 => 0,
            .int_comptime_int_i32 => 0,
            .int_small => @sizeOf(IntSmall),

            .int_positive,
            .int_negative,
            => b: {
                const int = ip.limbData(Int, data);
                break :b @sizeOf(Int) + int.limbs_len * 8;
            },

            .int_lazy_align, .int_lazy_size => @sizeOf(IntLazy),

            .error_set_error, .error_union_error => @sizeOf(Key.Error),
            .error_union_payload => @sizeOf(Tag.TypeValue),
            .enum_literal => 0,
            .enum_tag => @sizeOf(Key.EnumTag),

            .bytes => b: {
                const info = ip.extraData(Bytes, data);
                const len = @intCast(u32, ip.aggregateTypeLenIncludingSentinel(info.ty));
                break :b @sizeOf(Bytes) + len +
                    @boolToInt(ip.string_bytes.items[@enumToInt(info.bytes) + len - 1] != 0);
            },
            .aggregate => b: {
                const info = ip.extraData(Aggregate, data);
                const fields_len = @intCast(u32, ip.aggregateTypeLenIncludingSentinel(info.ty));
                break :b @sizeOf(Aggregate) + (@sizeOf(Index) * fields_len);
            },
            .repeated => @sizeOf(Repeated),

            .float_f16 => 0,
            .float_f32 => 0,
            .float_f64 => @sizeOf(Float64),
            .float_f80 => @sizeOf(Float80),
            .float_f128 => @sizeOf(Float128),
            .float_c_longdouble_f80 => @sizeOf(Float80),
            .float_c_longdouble_f128 => @sizeOf(Float128),
            .float_comptime_float => @sizeOf(Float128),
            .variable => @sizeOf(Tag.Variable) + @sizeOf(Module.Decl),
            .extern_func => @sizeOf(Key.ExternFunc) + @sizeOf(Module.Decl),
            .func => @sizeOf(Key.Func) + @sizeOf(Module.Fn) + @sizeOf(Module.Decl),
            .only_possible_value => 0,
            .union_value => @sizeOf(Key.Union),

            .memoized_decl => @sizeOf(Key.MemoizedDecl),
            .memoized_call => b: {
                const info = ip.extraData(MemoizedCall, data);
                break :b @sizeOf(MemoizedCall) + (@sizeOf(Index) * info.args_len);
            },
        });
    }
    const SortContext = struct {
        map: *std.AutoArrayHashMap(Tag, TagStats),
        pub fn lessThan(ctx: @This(), a_index: usize, b_index: usize) bool {
            const values = ctx.map.values();
            return values[a_index].bytes > values[b_index].bytes;
        }
    };
    counts.sort(SortContext{ .map = &counts });
    const len = @min(25, counts.count());
    std.debug.print("  top 25 tags:\n", .{});
    for (counts.keys()[0..len], counts.values()[0..len]) |tag, stats| {
        std.debug.print("    {s}: {d} occurrences, {d} total bytes\n", .{
            @tagName(tag), stats.count, stats.bytes,
        });
    }
}

pub fn structPtr(ip: *InternPool, index: Module.Struct.Index) *Module.Struct {
    return ip.allocated_structs.at(@enumToInt(index));
}

pub fn structPtrConst(ip: *const InternPool, index: Module.Struct.Index) *const Module.Struct {
    return ip.allocated_structs.at(@enumToInt(index));
}

pub fn structPtrUnwrapConst(ip: *const InternPool, index: Module.Struct.OptionalIndex) ?*const Module.Struct {
    return structPtrConst(ip, index.unwrap() orelse return null);
}

pub fn unionPtr(ip: *InternPool, index: Module.Union.Index) *Module.Union {
    return ip.allocated_unions.at(@enumToInt(index));
}

pub fn unionPtrConst(ip: *const InternPool, index: Module.Union.Index) *const Module.Union {
    return ip.allocated_unions.at(@enumToInt(index));
}

pub fn funcPtr(ip: *InternPool, index: Module.Fn.Index) *Module.Fn {
    return ip.allocated_funcs.at(@enumToInt(index));
}

pub fn funcPtrConst(ip: *const InternPool, index: Module.Fn.Index) *const Module.Fn {
    return ip.allocated_funcs.at(@enumToInt(index));
}

pub fn inferredErrorSetPtr(ip: *InternPool, index: Module.Fn.InferredErrorSet.Index) *Module.Fn.InferredErrorSet {
    return ip.allocated_inferred_error_sets.at(@enumToInt(index));
}

pub fn inferredErrorSetPtrConst(ip: *const InternPool, index: Module.Fn.InferredErrorSet.Index) *const Module.Fn.InferredErrorSet {
    return ip.allocated_inferred_error_sets.at(@enumToInt(index));
}

pub fn createStruct(
    ip: *InternPool,
    gpa: Allocator,
    initialization: Module.Struct,
) Allocator.Error!Module.Struct.Index {
    if (ip.structs_free_list.popOrNull()) |index| return index;
    const ptr = try ip.allocated_structs.addOne(gpa);
    ptr.* = initialization;
    return @intToEnum(Module.Struct.Index, ip.allocated_structs.len - 1);
}

pub fn destroyStruct(ip: *InternPool, gpa: Allocator, index: Module.Struct.Index) void {
    ip.structPtr(index).* = undefined;
    ip.structs_free_list.append(gpa, index) catch {
        // In order to keep `destroyStruct` a non-fallible function, we ignore memory
        // allocation failures here, instead leaking the Struct until garbage collection.
    };
}

pub fn createUnion(
    ip: *InternPool,
    gpa: Allocator,
    initialization: Module.Union,
) Allocator.Error!Module.Union.Index {
    if (ip.unions_free_list.popOrNull()) |index| return index;
    const ptr = try ip.allocated_unions.addOne(gpa);
    ptr.* = initialization;
    return @intToEnum(Module.Union.Index, ip.allocated_unions.len - 1);
}

pub fn destroyUnion(ip: *InternPool, gpa: Allocator, index: Module.Union.Index) void {
    ip.unionPtr(index).* = undefined;
    ip.unions_free_list.append(gpa, index) catch {
        // In order to keep `destroyUnion` a non-fallible function, we ignore memory
        // allocation failures here, instead leaking the Union until garbage collection.
    };
}

pub fn createFunc(
    ip: *InternPool,
    gpa: Allocator,
    initialization: Module.Fn,
) Allocator.Error!Module.Fn.Index {
    if (ip.funcs_free_list.popOrNull()) |index| return index;
    const ptr = try ip.allocated_funcs.addOne(gpa);
    ptr.* = initialization;
    return @intToEnum(Module.Fn.Index, ip.allocated_funcs.len - 1);
}

pub fn destroyFunc(ip: *InternPool, gpa: Allocator, index: Module.Fn.Index) void {
    ip.funcPtr(index).* = undefined;
    ip.funcs_free_list.append(gpa, index) catch {
        // In order to keep `destroyFunc` a non-fallible function, we ignore memory
        // allocation failures here, instead leaking the Union until garbage collection.
    };
}

pub fn createInferredErrorSet(
    ip: *InternPool,
    gpa: Allocator,
    initialization: Module.Fn.InferredErrorSet,
) Allocator.Error!Module.Fn.InferredErrorSet.Index {
    if (ip.inferred_error_sets_free_list.popOrNull()) |index| return index;
    const ptr = try ip.allocated_inferred_error_sets.addOne(gpa);
    ptr.* = initialization;
    return @intToEnum(Module.Fn.InferredErrorSet.Index, ip.allocated_inferred_error_sets.len - 1);
}

pub fn destroyInferredErrorSet(ip: *InternPool, gpa: Allocator, index: Module.Fn.InferredErrorSet.Index) void {
    ip.inferredErrorSetPtr(index).* = undefined;
    ip.inferred_error_sets_free_list.append(gpa, index) catch {
        // In order to keep `destroyInferredErrorSet` a non-fallible function, we ignore memory
        // allocation failures here, instead leaking the InferredErrorSet until garbage collection.
    };
}

pub fn getOrPutString(
    ip: *InternPool,
    gpa: Allocator,
    s: []const u8,
) Allocator.Error!NullTerminatedString {
    const string_bytes = &ip.string_bytes;
    try string_bytes.ensureUnusedCapacity(gpa, s.len + 1);
    string_bytes.appendSliceAssumeCapacity(s);
    string_bytes.appendAssumeCapacity(0);
    return ip.getOrPutTrailingString(gpa, s.len + 1);
}

/// Uses the last len bytes of ip.string_bytes as the key.
pub fn getOrPutTrailingString(
    ip: *InternPool,
    gpa: Allocator,
    len: usize,
) Allocator.Error!NullTerminatedString {
    const string_bytes = &ip.string_bytes;
    const str_index = @intCast(u32, string_bytes.items.len - len);
    if (len > 0 and string_bytes.getLast() == 0) {
        _ = string_bytes.pop();
    } else {
        try string_bytes.ensureUnusedCapacity(gpa, 1);
    }
    const key: []const u8 = string_bytes.items[str_index..];
    const gop = try ip.string_table.getOrPutContextAdapted(gpa, key, std.hash_map.StringIndexAdapter{
        .bytes = string_bytes,
    }, std.hash_map.StringIndexContext{
        .bytes = string_bytes,
    });
    if (gop.found_existing) {
        string_bytes.shrinkRetainingCapacity(str_index);
        return @intToEnum(NullTerminatedString, gop.key_ptr.*);
    } else {
        gop.key_ptr.* = str_index;
        string_bytes.appendAssumeCapacity(0);
        return @intToEnum(NullTerminatedString, str_index);
    }
}

pub fn getString(ip: *InternPool, s: []const u8) OptionalNullTerminatedString {
    if (ip.string_table.getKeyAdapted(s, std.hash_map.StringIndexAdapter{
        .bytes = &ip.string_bytes,
    })) |index| {
        return @intToEnum(NullTerminatedString, index).toOptional();
    } else {
        return .none;
    }
}

pub fn stringToSlice(ip: *const InternPool, s: NullTerminatedString) [:0]const u8 {
    const string_bytes = ip.string_bytes.items;
    const start = @enumToInt(s);
    var end: usize = start;
    while (string_bytes[end] != 0) end += 1;
    return string_bytes[start..end :0];
}

pub fn stringToSliceUnwrap(ip: *const InternPool, s: OptionalNullTerminatedString) ?[:0]const u8 {
    return ip.stringToSlice(s.unwrap() orelse return null);
}

pub fn typeOf(ip: *const InternPool, index: Index) Index {
    // This optimization of static keys is required so that typeOf can be called
    // on static keys that haven't been added yet during static key initialization.
    // An alternative would be to topological sort the static keys, but this would
    // mean that the range of type indices would not be dense.
    return switch (index) {
        .u1_type,
        .u8_type,
        .i8_type,
        .u16_type,
        .i16_type,
        .u29_type,
        .u32_type,
        .i32_type,
        .u64_type,
        .i64_type,
        .u80_type,
        .u128_type,
        .i128_type,
        .usize_type,
        .isize_type,
        .c_char_type,
        .c_short_type,
        .c_ushort_type,
        .c_int_type,
        .c_uint_type,
        .c_long_type,
        .c_ulong_type,
        .c_longlong_type,
        .c_ulonglong_type,
        .c_longdouble_type,
        .f16_type,
        .f32_type,
        .f64_type,
        .f80_type,
        .f128_type,
        .anyopaque_type,
        .bool_type,
        .void_type,
        .type_type,
        .anyerror_type,
        .comptime_int_type,
        .comptime_float_type,
        .noreturn_type,
        .anyframe_type,
        .null_type,
        .undefined_type,
        .enum_literal_type,
        .atomic_order_type,
        .atomic_rmw_op_type,
        .calling_convention_type,
        .address_space_type,
        .float_mode_type,
        .reduce_op_type,
        .call_modifier_type,
        .prefetch_options_type,
        .export_options_type,
        .extern_options_type,
        .type_info_type,
        .manyptr_u8_type,
        .manyptr_const_u8_type,
        .manyptr_const_u8_sentinel_0_type,
        .single_const_pointer_to_comptime_int_type,
        .slice_const_u8_type,
        .slice_const_u8_sentinel_0_type,
        .anyerror_void_error_union_type,
        .generic_poison_type,
        .empty_struct_type,
        => .type_type,

        .undef => .undefined_type,
        .zero, .one, .negative_one => .comptime_int_type,
        .zero_usize, .one_usize => .usize_type,
        .zero_u8, .one_u8, .four_u8 => .u8_type,
        .calling_convention_c, .calling_convention_inline => .calling_convention_type,
        .void_value => .void_type,
        .unreachable_value => .noreturn_type,
        .null_value => .null_type,
        .bool_true, .bool_false => .bool_type,
        .empty_struct => .empty_struct_type,
        .generic_poison => .generic_poison_type,

        // This optimization on tags is needed so that indexToKey can call
        // typeOf without being recursive.
        _ => switch (ip.items.items(.tag)[@enumToInt(index)]) {
            .type_int_signed,
            .type_int_unsigned,
            .type_array_big,
            .type_array_small,
            .type_vector,
            .type_pointer,
            .type_slice,
            .type_optional,
            .type_anyframe,
            .type_error_union,
            .type_error_set,
            .type_inferred_error_set,
            .type_enum_auto,
            .type_enum_explicit,
            .type_enum_nonexhaustive,
            .simple_type,
            .type_opaque,
            .type_struct,
            .type_struct_ns,
            .type_struct_anon,
            .type_tuple_anon,
            .type_union_tagged,
            .type_union_untagged,
            .type_union_safety,
            .type_function,
            => .type_type,

            .undef,
            .opt_null,
            .only_possible_value,
            => @intToEnum(Index, ip.items.items(.data)[@enumToInt(index)]),

            .simple_value => unreachable, // handled via Index above

            inline .ptr_decl,
            .ptr_mut_decl,
            .ptr_comptime_field,
            .ptr_int,
            .ptr_eu_payload,
            .ptr_opt_payload,
            .ptr_elem,
            .ptr_field,
            .ptr_slice,
            .opt_payload,
            .error_union_payload,
            .runtime_value,
            .int_small,
            .int_lazy_align,
            .int_lazy_size,
            .error_set_error,
            .error_union_error,
            .enum_tag,
            .variable,
            .extern_func,
            .func,
            .union_value,
            .bytes,
            .aggregate,
            .repeated,
            => |t| {
                const extra_index = ip.items.items(.data)[@enumToInt(index)];
                const field_index = std.meta.fieldIndex(t.Payload(), "ty").?;
                return @intToEnum(Index, ip.extra.items[extra_index + field_index]);
            },

            .int_u8 => .u8_type,
            .int_u16 => .u16_type,
            .int_u32 => .u32_type,
            .int_i32 => .i32_type,
            .int_usize => .usize_type,

            .int_comptime_int_u32,
            .int_comptime_int_i32,
            => .comptime_int_type,

            // Note these are stored in limbs data, not extra data.
            .int_positive,
            .int_negative,
            => ip.limbData(Int, ip.items.items(.data)[@enumToInt(index)]).ty,

            .enum_literal => .enum_literal_type,
            .float_f16 => .f16_type,
            .float_f32 => .f32_type,
            .float_f64 => .f64_type,
            .float_f80 => .f80_type,
            .float_f128 => .f128_type,

            .float_c_longdouble_f80,
            .float_c_longdouble_f128,
            => .c_longdouble_type,

            .float_comptime_float => .comptime_float_type,

            .memoized_decl => unreachable,
            .memoized_call => unreachable,
        },

        .var_args_param_type => unreachable,
        .none => unreachable,
    };
}

/// Assumes that the enum's field indexes equal its value tags.
pub fn toEnum(ip: *const InternPool, comptime E: type, i: Index) E {
    const int = ip.indexToKey(i).enum_tag.int;
    return @intToEnum(E, ip.indexToKey(int).int.storage.u64);
}

pub fn aggregateTypeLen(ip: *const InternPool, ty: Index) u64 {
    return switch (ip.indexToKey(ty)) {
        .struct_type => |struct_type| ip.structPtrConst(struct_type.index.unwrap() orelse return 0).fields.count(),
        .anon_struct_type => |anon_struct_type| anon_struct_type.types.len,
        .array_type => |array_type| array_type.len,
        .vector_type => |vector_type| vector_type.len,
        else => unreachable,
    };
}

pub fn aggregateTypeLenIncludingSentinel(ip: *const InternPool, ty: Index) u64 {
    return switch (ip.indexToKey(ty)) {
        .struct_type => |struct_type| ip.structPtrConst(struct_type.index.unwrap() orelse return 0).fields.count(),
        .anon_struct_type => |anon_struct_type| anon_struct_type.types.len,
        .array_type => |array_type| array_type.len + @boolToInt(array_type.sentinel != .none),
        .vector_type => |vector_type| vector_type.len,
        else => unreachable,
    };
}

pub fn isNoReturn(ip: *const InternPool, ty: Index) bool {
    return switch (ty) {
        .noreturn_type => true,
        else => switch (ip.indexToKey(ty)) {
            .error_set_type => |error_set_type| error_set_type.names.len == 0,
            .enum_type => |enum_type| enum_type.names.len == 0,
            else => false,
        },
    };
}

/// This is a particularly hot function, so we operate directly on encodings
/// rather than the more straightforward implementation of calling `indexToKey`.
pub fn zigTypeTagOrPoison(ip: *const InternPool, index: Index) error{GenericPoison}!std.builtin.TypeId {
    return switch (index) {
        .u1_type,
        .u8_type,
        .i8_type,
        .u16_type,
        .i16_type,
        .u29_type,
        .u32_type,
        .i32_type,
        .u64_type,
        .i64_type,
        .u80_type,
        .u128_type,
        .i128_type,
        .usize_type,
        .isize_type,
        .c_char_type,
        .c_short_type,
        .c_ushort_type,
        .c_int_type,
        .c_uint_type,
        .c_long_type,
        .c_ulong_type,
        .c_longlong_type,
        .c_ulonglong_type,
        => .Int,

        .c_longdouble_type,
        .f16_type,
        .f32_type,
        .f64_type,
        .f80_type,
        .f128_type,
        => .Float,

        .anyopaque_type => .Opaque,
        .bool_type => .Bool,
        .void_type => .Void,
        .type_type => .Type,
        .anyerror_type => .ErrorSet,
        .comptime_int_type => .ComptimeInt,
        .comptime_float_type => .ComptimeFloat,
        .noreturn_type => .NoReturn,
        .anyframe_type => .AnyFrame,
        .null_type => .Null,
        .undefined_type => .Undefined,
        .enum_literal_type => .EnumLiteral,

        .atomic_order_type,
        .atomic_rmw_op_type,
        .calling_convention_type,
        .address_space_type,
        .float_mode_type,
        .reduce_op_type,
        .call_modifier_type,
        => .Enum,

        .prefetch_options_type,
        .export_options_type,
        .extern_options_type,
        => .Struct,

        .type_info_type => .Union,

        .manyptr_u8_type,
        .manyptr_const_u8_type,
        .manyptr_const_u8_sentinel_0_type,
        .single_const_pointer_to_comptime_int_type,
        .slice_const_u8_type,
        .slice_const_u8_sentinel_0_type,
        => .Pointer,

        .anyerror_void_error_union_type => .ErrorUnion,
        .empty_struct_type => .Struct,

        .generic_poison_type => return error.GenericPoison,

        // values, not types
        .undef => unreachable,
        .zero => unreachable,
        .zero_usize => unreachable,
        .zero_u8 => unreachable,
        .one => unreachable,
        .one_usize => unreachable,
        .one_u8 => unreachable,
        .four_u8 => unreachable,
        .negative_one => unreachable,
        .calling_convention_c => unreachable,
        .calling_convention_inline => unreachable,
        .void_value => unreachable,
        .unreachable_value => unreachable,
        .null_value => unreachable,
        .bool_true => unreachable,
        .bool_false => unreachable,
        .empty_struct => unreachable,
        .generic_poison => unreachable,

        .var_args_param_type => unreachable, // special tag

        _ => switch (ip.items.items(.tag)[@enumToInt(index)]) {
            .type_int_signed,
            .type_int_unsigned,
            => .Int,

            .type_array_big,
            .type_array_small,
            => .Array,

            .type_vector => .Vector,

            .type_pointer,
            .type_slice,
            => .Pointer,

            .type_optional => .Optional,
            .type_anyframe => .AnyFrame,
            .type_error_union => .ErrorUnion,

            .type_error_set,
            .type_inferred_error_set,
            => .ErrorSet,

            .type_enum_auto,
            .type_enum_explicit,
            .type_enum_nonexhaustive,
            => .Enum,

            .simple_type => unreachable, // handled via Index tag above

            .type_opaque => .Opaque,

            .type_struct,
            .type_struct_ns,
            .type_struct_anon,
            .type_tuple_anon,
            => .Struct,

            .type_union_tagged,
            .type_union_untagged,
            .type_union_safety,
            => .Union,

            .type_function => .Fn,

            // values, not types
            .undef,
            .runtime_value,
            .simple_value,
            .ptr_decl,
            .ptr_mut_decl,
            .ptr_comptime_field,
            .ptr_int,
            .ptr_eu_payload,
            .ptr_opt_payload,
            .ptr_elem,
            .ptr_field,
            .ptr_slice,
            .opt_payload,
            .opt_null,
            .int_u8,
            .int_u16,
            .int_u32,
            .int_i32,
            .int_usize,
            .int_comptime_int_u32,
            .int_comptime_int_i32,
            .int_small,
            .int_positive,
            .int_negative,
            .int_lazy_align,
            .int_lazy_size,
            .error_set_error,
            .error_union_error,
            .error_union_payload,
            .enum_literal,
            .enum_tag,
            .float_f16,
            .float_f32,
            .float_f64,
            .float_f80,
            .float_f128,
            .float_c_longdouble_f80,
            .float_c_longdouble_f128,
            .float_comptime_float,
            .variable,
            .extern_func,
            .func,
            .only_possible_value,
            .union_value,
            .bytes,
            .aggregate,
            .repeated,
            // memoization, not types
            .memoized_decl,
            .memoized_call,
            => unreachable,
        },
        .none => unreachable, // special tag
    };
}
