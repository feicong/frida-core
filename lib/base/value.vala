namespace Frida {
    // ObjectBuilder 接口，定义构建对象的方法
    public interface ObjectBuilder : Object {
        // 开始一个字典对象
        public abstract unowned ObjectBuilder begin_dictionary ();
        // 设置字典成员名称
        public abstract unowned ObjectBuilder set_member_name (string name);
        // 结束字典对象
        public abstract unowned ObjectBuilder end_dictionary ();

        // 开始一个数组对象
        public abstract unowned ObjectBuilder begin_array ();
        // 结束数组对象
        public abstract unowned ObjectBuilder end_array ();

        // 添加空值
        public abstract unowned ObjectBuilder add_null_value ();
        // 添加布尔值
        public abstract unowned ObjectBuilder add_bool_value (bool val);
        // 添加 int64 类型值
        public abstract unowned ObjectBuilder add_int64_value (int64 val);
        // 添加 uint64 类型值
        public abstract unowned ObjectBuilder add_uint64_value (uint64 val);
        // 添加字节数据值
        public abstract unowned ObjectBuilder add_data_value (Bytes val);
        // 添加字符串值
        public abstract unowned ObjectBuilder add_string_value (string val);
        // 添加 UUID 值
        public abstract unowned ObjectBuilder add_uuid_value (uint8[] val);
        // 添加原始值
        public abstract unowned ObjectBuilder add_raw_value (Bytes val);

        // 构建并返回 Bytes 对象
        public abstract Bytes build ();
    }

    // ObjectReader 接口，定义读取对象数据的方法
    public interface ObjectReader : Object {
        // 检查是否有指定名称的成员
        public abstract bool has_member (string name) throws Error;
        // 读取指定名称的成员
        public abstract unowned ObjectReader read_member (string name) throws Error;
        // 结束成员读取
        public abstract unowned ObjectReader end_member ();

        // 获取元素数量
        public abstract uint count_elements () throws Error;
        // 读取指定索引的元素
        public abstract unowned ObjectReader read_element (uint index) throws Error;
        // 结束元素读取
        public abstract unowned ObjectReader end_element () throws Error;

        // 获取布尔值
        public abstract bool get_bool_value () throws Error;
        // 获取 uint8 值
        public abstract uint8 get_uint8_value () throws Error;
        // 获取 uint16 值
        public abstract uint16 get_uint16_value () throws Error;
        // 获取 int64 值
        public abstract int64 get_int64_value () throws Error;
        // 获取 uint64 值
        public abstract uint64 get_uint64_value () throws Error;
        // 获取字节数据值
        public abstract Bytes get_data_value () throws Error;
        // 获取字符串值
        public abstract unowned string get_string_value () throws Error;
        // 获取 UUID 值
        public abstract unowned string get_uuid_value () throws Error;
    }

    // VariantReader 类，实现 ObjectReader 接口，用于读取 GLib Variant 数据
    public class VariantReader : Object, ObjectReader {
        // 获取根对象
        public Variant root_object {
            get {
                return scopes.peek_head ().val;
            }
        }

        // 获取当前对象
        public Variant current_object {
            get {
                return scopes.peek_tail ().val;
            }
        }

        // 存储作用域的双端队列
        private Gee.Deque<Scope> scopes = new Gee.ArrayQueue<Scope> ();

        // 构造函数，初始化 VariantReader 对象
        public VariantReader (Variant v) {
            push_scope (v);
        }

        // 检查是否有指定名称的成员
        public bool has_member (string name) throws Error {
            var scope = peek_scope ();
            if (scope.dict == null)
                throw new Error.PROTOCOL ("Dictionary expected, but at %s", scope.val.print (true));
            return scope.dict.contains (name);
        }

        // 读取指定名称的成员
        public unowned ObjectReader read_member (string name) throws Error {
            var scope = peek_scope ();
            if (scope.dict == null)
                throw new Error.PROTOCOL ("Dictionary expected, but at %s", scope.val.print (true));

            Variant? v = scope.dict.lookup_value (name, null);
            if (v == null)
                throw new Error.PROTOCOL ("Key '%s' not found in dictionary: %s", name, scope.val.print (true));

            push_scope (v);

            return this;
        }

        // 结束成员读取
        public unowned ObjectReader end_member () {
            pop_scope ();

            return this;
        }

        // 获取元素数量
        public uint count_elements () throws Error {
            var scope = peek_scope ();
            scope.check_array ();
            return (uint) scope.val.n_children ();
        }

        // 读取指定索引的元素
        public unowned ObjectReader read_element (uint index) throws Error {
            var scope = peek_scope ();
            scope.check_array ();
            push_scope (scope.val.get_child_value (index).get_variant ());

            return this;
        }

        // 结束元素读取
        public unowned ObjectReader end_element () {
            pop_scope ();

            return this;
        }

        // 获取布尔值
        public bool get_bool_value () throws Error {
            return peek_scope ().get_value (VariantType.BOOLEAN).get_boolean ();
        }

        // 获取 uint8 值
        public uint8 get_uint8_value () throws Error {
            return peek_scope ().get_value (VariantType.BYTE).get_byte ();
        }

        // 获取 uint16 值
        public uint16 get_uint16_value () throws Error {
            return peek_scope ().get_value (VariantType.UINT16).get_uint16 ();
        }

        // 获取 int64 值
        public int64 get_int64_value () throws Error {
            return peek_scope ().get_value (VariantType.INT64).get_int64 ();
        }

        // 获取 uint64 值
        public uint64 get_uint64_value () throws Error {
            return peek_scope ().get_value (VariantType.UINT64).get_uint64 ();
        }

        // 获取字节数据值
        public Bytes get_data_value () throws Error {
            return peek_scope ().get_value (new VariantType.array (VariantType.BYTE)).get_data_as_bytes ();
        }

        // 获取字符串值
        public unowned string get_string_value () throws Error {
            return peek_scope ().get_value (VariantType.STRING).get_string ();
        }

        // 获取 UUID 值
        public unowned string get_uuid_value () throws Error {
            return peek_scope ().get_value (VariantType.STRING).get_string (); // TODO: Use a tuple to avoid ambiguity.
        }

        // 将 Variant 压入作用域
        private void push_scope (Variant v) {
            scopes.offer_tail (new Scope (v));
        }

        // 获取当前作用域
        private Scope peek_scope () {
            return scopes.peek_tail ();
        }

        // 弹出当前作用域
        private Scope pop_scope () {
            return scopes.poll_tail ();
        }

        // 内部类，表示作用域
        private class Scope {
            public Variant val;
            public VariantDict? dict;
            public bool is_array = false;

            // 构造函数，初始化 Scope 对象
            public Scope (Variant v) {
                val = v;

                VariantType t = v.get_type ();
                if (t.equal (VariantType.VARDICT))
                    dict = new VariantDict (v);
                else if (t.is_subtype_of (VariantType.ARRAY))
                    is_array = true;
            }

            // 获取指定类型的值
            public Variant get_value (VariantType expected_type) throws Error {
                if (!val.get_type ().equal (expected_type)) {
                    throw new Error.PROTOCOL ("Expected type '%s', got '%s'",
                        (string) expected_type.peek_string (),
                        (string) val.get_type ().peek_string ());
                }

                return val;
            }

            // 检查是否为数组
            public void check_array () throws Error {
                if (!is_array)
                    throw new Error.PROTOCOL ("Array expected, but at %s", val.print (true));
            }
        }
    }

    // JsonObjectBuilder 类，实现 ObjectBuilder 接口，用于构建 JSON 对象
    public class JsonObjectBuilder : Object, ObjectBuilder {
        private Json.Builder builder = new Json.Builder ();
        private Gee.Map<string, Bytes> raw_values = new Gee.HashMap<string, Bytes> ();

        // 开始一个字典对象
        public unowned ObjectBuilder begin_dictionary () {
            builder.begin_object ();
            return this;
        }

        // 设置字典成员名称
        public unowned ObjectBuilder set_member_name (string name) {
            builder.set_member_name (name);
            return this;
        }

        // 结束字典对象
        public unowned ObjectBuilder end_dictionary () {
            builder.end_object ();
            return this;
        }

        // 开始一个数组对象
        public unowned ObjectBuilder begin_array () {
            builder.begin_array ();
            return this;
        }

        // 结束数组对象
        public unowned ObjectBuilder end_array () {
            builder.end_array ();
            return this;
        }

        // 添加空值
        public unowned ObjectBuilder add_null_value () {
            builder.add_null_value ();
            return this;
        }

        // 添加布尔值
        public unowned ObjectBuilder add_bool_value (bool val) {
            builder.add_boolean_value (val);
            return this;
        }

        // 添加 int64 类型值
        public unowned ObjectBuilder add_int64_value (int64 val) {
            builder.add_int_value (val);
            return this;
        }

        // 添加 uint64 类型值
        public unowned ObjectBuilder add_uint64_value (uint64 val) {
            builder.add_int_value ((int64) val);
            return this;
        }

        // 添加字节数据值
        public unowned ObjectBuilder add_data_value (Bytes val) {
            builder.add_string_value (Base64.encode (val.get_data ()));
            return this;
        }

        // 添加字符串值
        public unowned ObjectBuilder add_string_value (string val) {
            builder.add_string_value (val);
            return this;
        }

        // 添加 UUID 值
        public unowned ObjectBuilder add_uuid_value (uint8[] val) {
            assert_not_reached ();
        }

        // 添加原始值
        public unowned ObjectBuilder add_raw_value (Bytes val) {
            string uuid = Uuid.string_random ();
            builder.add_string_value (uuid);
            raw_values[uuid] = val;
            return this;
        }

        // 构建并返回 Bytes 对象
        public Bytes build () {
            string json = Json.to_string (builder.get_root (), false);

            foreach (var e in raw_values.entries) {
                unowned string uuid = e.key;
                Bytes val = e.value;

                unowned string raw_str = (string) val.get_data ();
                string str = raw_str[:(long) val.get_size ()];

                json = json.replace ("\"" + uuid + "\"", str);
            }

            return new Bytes (json.data);
        }
    }

    // JsonObjectReader 类，实现 ObjectReader 接口，用于读取 JSON 对象
    public class JsonObjectReader : Object, ObjectReader {
        private Json.Reader reader;

        // 构造函数，初始化 JsonObjectReader 对象
        public JsonObjectReader (string json) throws Error {
            try {
                reader = new Json.Reader (Json.from_string (json));
            } catch (GLib.Error e) {
                throw new Error.INVALID_ARGUMENT ("%s", e.message);
            }
        }

        // 检查是否有指定名称的成员
        public bool has_member (string name) throws Error {
            bool result = reader.read_member (name);
            reader.end_member ();
            return result;
        }

        // 读取指定名称的成员
        public unowned ObjectReader read_member (string name) throws Error {
            if (!reader.read_member (name))
                throw_dict_access_error ();
            return this;
        }

        // 结束成员读取
        public unowned ObjectReader end_member () {
            reader.end_member ();
            return this;
        }

        // 抛出字典访问错误
        [NoReturn]
        private void throw_dict_access_error () throws Error {
            GLib.Error e = reader.get_error ();
            reader.end_member ();
            throw new Error.PROTOCOL ("%s", e.message);
        }

        // 获取元素数量
        public uint count_elements () throws Error {
            int n = reader.count_elements ();
            if (n == -1)
                throw_array_access_error ();
            return n;
        }

        // 读取指定索引的元素
        public unowned ObjectReader read_element (uint index) throws Error {
            if (!reader.read_element (index)) {
                GLib.Error e = reader.get_error ();
                reader.end_element ();
                throw new Error.PROTOCOL ("%s", e.message);
            }
            return this;
        }

        // 结束元素读取
        public unowned ObjectReader end_element () throws Error {
            reader.end_element ();
            return this;
        }

        // 抛出数组访问错误
        [NoReturn]
        private void throw_array_access_error () throws Error {
            GLib.Error e = reader.get_error ();
            reader.end_element ();
            throw new Error.PROTOCOL ("%s", e.message);
        }

        // 获取布尔值
        public bool get_bool_value () throws Error {
            bool v = reader.get_boolean_value ();
            if (!v)
                maybe_throw_value_access_error ();
            return v;
        }

        // 获取 uint8 值
        public uint8 get_uint8_value () throws Error {
            int64 v = get_int64_value ();
            if (v < 0 || v > uint8.MAX)
                throw new Error.PROTOCOL ("Invalid uint8");
            return (uint8) v;
        }

        // 获取 uint16 值
        public uint16 get_uint16_value () throws Error {
            int64 v = get_int64_value ();
            if (v < 0 || v > uint16.MAX)
                throw new Error.PROTOCOL ("Invalid uint16");
            return (uint16) v;
        }

        // 获取 int64 值
        public int64 get_int64_value () throws Error {
            int64 v = reader.get_int_value ();
            if (v == 0)
                maybe_throw_value_access_error ();
            return v;
        }

        // 获取 uint64 值
        public uint64 get_uint64_value () throws Error {
            int64 v = get_int64_value ();
            if (v < 0)
                throw new Error.PROTOCOL ("Invalid uint64");
            return v;
        }

        // 获取字节数据值
        public Bytes get_data_value () throws Error {
            return new Bytes (Base64.decode (get_string_value ()));
        }

        // 获取字符串值
        public unowned string get_string_value () throws Error {
            unowned string? v = reader.get_string_value ();
            if (v == null)
                maybe_throw_value_access_error ();
            return v;
        }

        // 获取 UUID 值
        public unowned string get_uuid_value () throws Error {
            return get_string_value ();
        }

        // 检查并抛出值访问错误
        private void maybe_throw_value_access_error () throws Error {
            GLib.Error? e = reader.get_error ();
            if (e == null)
                return;
            reader.end_member ();
            throw new Error.PROTOCOL ("%s", e.message);
        }
    }
}
