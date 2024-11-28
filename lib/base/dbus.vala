namespace Frida {
	// We need to tease out GDBus' private MainContext as libnice needs to know the MainContext up front :(
    // 获取与DBus相关联的MainContext。
    // 使用异步操作处理DBus连接和操作。
    public async MainContext get_dbus_context () {
        if (get_context_request != null) {
            try {
                // 等待上下文请求完成并返回结果。
                return yield get_context_request.future.wait_async (null);
            } catch (GLib.Error e) {
                // 如果发生错误，不应到达这里（断言未到达）。
                assert_not_reached ();
            }
        }
        // 创建一个新的Promise以获取MainContext。
        get_context_request = new Promise<MainContext> ();

        MainContext dbus_context;
        try {
            // 创建虚拟输入和输出流。
            var input = new DummyInputStream ();
            var output = new MemoryOutputStream (null);
            // 使用流建立新的DBus连接。
            var connection = yield new DBusConnection (new SimpleIOStream (input, output), null, 0, null, null);

            // 获取调用者的主上下文。
            var caller_context = MainContext.ref_thread_default ();
            int filter_calls = 0;

            // 添加过滤器到DBus连接以捕获MainContext。
            uint filter_id = connection.add_filter ((connection, message, incoming) => {
                MainContext ctx = MainContext.ref_thread_default ();

                // 确保过滤器仅被调用一次。
                if (AtomicInt.add (ref filter_calls, 1) == 0) {
                    var idle_source = new IdleSource ();
                    idle_source.set_callback (() => {
                        // 用捕获的MainContext解析Promise。
                        get_context_request.resolve (ctx);
                        return false;
                    });
                    idle_source.attach (caller_context);
                }

                return message;
            });

            var io_cancellable = new Cancellable ();
            // 开始在DBus连接上获取代理。
            do_get_proxy.begin (connection, io_cancellable);

            // 等待上下文请求完成并获取DBus上下文。
            dbus_context = yield get_context_request.future.wait_async (null);

            // 通过取消操作和移除过滤器进行清理。
            io_cancellable.cancel ();
            connection.remove_filter (filter_id);
            input.unblock ();
            yield connection.close ();
        } catch (GLib.Error e) {
            // 如果发生错误，不应到达这里（断言未到达）。
            assert_not_reached ();
        }

        return dbus_context;
    }

    // 使存储的DBus上下文请求无效。
    public void invalidate_dbus_context () {
        get_context_request = null;
    }

    private Promise<MainContext>? get_context_request;

    // 异步函数，在DBus连接上获取代理。
    private async HostSession do_get_proxy (DBusConnection connection, Cancellable cancellable) throws IOError {
        return yield connection.get_proxy (null, ObjectPath.HOST_SESSION, DBusProxyFlags.NONE, cancellable);
    }

    // 表示用于DBus连接的虚拟输入流的类。
    private class DummyInputStream : InputStream {
        private bool done = false;
        private Mutex mutex;
        private Cond cond;

        // 解锁输入流。
        public void unblock () {
            mutex.lock ();
            done = true;
            cond.signal ();
            mutex.unlock ();
        }

        // 关闭输入流。
        public override bool close (Cancellable? cancellable) throws GLib.IOError {
            return true;
        }

        // 从输入流读取，直到被解锁。
        public override ssize_t read (uint8[] buffer, GLib.Cancellable? cancellable) throws GLib.IOError {
            mutex.lock ();
            while (!done)
                cond.wait (mutex);
            mutex.unlock ();
            return 0;
        }
    }
}
