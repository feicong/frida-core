namespace Frida {
    // Promise 类，泛型 T 表示 Promise 可以处理的结果类型
    public class Promise<T> {
        // 内部实现类实例
        private Impl<T> impl;

        // 获取 Future 对象，表示异步操作的结果
        public Future<T> future {
            get {
                return impl;
            }
        }

        // 构造函数，初始化内部实现类
        public Promise () {
            impl = new Impl<T> ();
        }

        // 析构函数，当对象被销毁时调用，放弃当前 Promise
        ~Promise () {
            impl.abandon ();
        }

        // 解析 Promise，设置成功结果
        public void resolve (T result) {
            impl.resolve (result);
        }

        // 拒绝 Promise，设置错误结果
        public void reject (GLib.Error error) {
            impl.reject (error);
        }

        // 内部实现类，继承自 Object 并实现 Future<T> 接口
        private class Impl<T> : Object, Future<T> {
            // 表示异步操作是否已完成
            public bool ready {
                get {
                    return _ready;
                }
            }
            private bool _ready = false;

            // 获取异步操作的结果
            public T? value {
                get {
                    return _value;
                }
            }
            private T? _value;

            // 获取异步操作的错误
            public GLib.Error? error {
                get {
                    return _error;
                }
            }
            private GLib.Error? _error;

            // 存储完成回调队列
            private Gee.ArrayQueue<CompletionFuncEntry> on_complete;

            // 异步等待方法，等待异步操作完成，返回结果或抛出错误
            public async T wait_async (Cancellable? cancellable) throws Frida.Error, IOError {
                if (_ready)
                    return get_result ();

                var entry = new CompletionFuncEntry (wait_async.callback);
                if (on_complete == null)
                    on_complete = new Gee.ArrayQueue<CompletionFuncEntry> ();
                on_complete.offer (entry);

                var cancel_source = new CancellableSource (cancellable);
                cancel_source.set_callback (() => {
                    on_complete.remove (entry);
                    wait_async.callback ();
                    return false;
                });
                cancel_source.attach (MainContext.get_thread_default ());

                yield;

                cancel_source.destroy ();

                cancellable.set_error_if_cancelled ();

                return get_result ();
            }

            // 获取异步操作的结果，抛出错误（如果有）
            private T get_result () throws Frida.Error, IOError {
                if (error != null) {
                    if (error is Frida.Error)
                        throw (Frida.Error) error;

                    if (error is IOError.CANCELLED)
                        throw (IOError) error;

                    throw new Frida.Error.TRANSPORT ("%s", error.message);
                }

                return _value;
            }

            // 内部方法，设置成功结果并标记为已完成
            internal void resolve (T value) {
                assert (!_ready);

                _value = value;
                transition_to_ready ();
            }

            // 内部方法，设置错误结果并标记为已完成
            internal void reject (GLib.Error error) {
                assert (!_ready);

                _error = error;
                transition_to_ready ();
            }

            // 内部方法，放弃当前 Promise，设置错误结果
            internal void abandon () {
                if (!_ready) {
                    reject (new Frida.Error.INVALID_OPERATION ("Promise abandoned"));
                }
            }

            // 内部方法，将 Promise 标记为已完成，并执行所有等待完成的回调
            internal void transition_to_ready () {
                _ready = true;

                if (on_complete != null && !on_complete.is_empty) {
                    var source = new IdleSource ();
                    source.set_priority (Priority.HIGH);
                    source.set_callback (() => {
                        CompletionFuncEntry? entry;
                        while ((entry = on_complete.poll ()) != null)
                            entry.func ();
                        on_complete = null;
                        return false;
                    });
                    source.attach (MainContext.get_thread_default ());
                }
            }
        }

        // 完成回调函数条目类
        private class CompletionFuncEntry {
            public SourceFunc func;

            public CompletionFuncEntry (owned SourceFunc func) {
                this.func = (owned) func;
            }
        }
    }

    // Future 接口，定义了获取异步操作状态和结果的方法
    public interface Future<T> : Object {
        public abstract bool ready { get; }
        public abstract T? value { get; }
        public abstract GLib.Error? error { get; }
        public abstract async T wait_async (Cancellable? cancellable) throws Frida.Error, IOError;
    }
}
