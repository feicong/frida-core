namespace Frida {
    // RpcClient 类，用于处理 RPC 请求和响应
    public class RpcClient : Object {
        // 弱引用的 RpcPeer 对象，用于发送和接收 RPC 消息
        public weak RpcPeer peer {
            get;
            construct;
        }

        // 存储待处理响应的哈希表，键为请求 ID
        private Gee.HashMap<string, PendingResponse> pending_responses = new Gee.HashMap<string, PendingResponse> ();

        // 构造函数，初始化 RpcClient 对象
        public RpcClient (RpcPeer peer) {
            Object (peer: peer);
        }

        // 异步调用方法，发送 RPC 请求并等待响应
        public async Json.Node call (string method, Json.Node[] args, Bytes? data, Cancellable? cancellable) throws Error, IOError {
            // 生成唯一的请求 ID
            string request_id = Uuid.string_random ();

            // 构建 JSON 请求
            var request = new Json.Builder ();
            request
                .begin_array ()
                .add_string_value ("frida:rpc")
                .add_string_value (request_id)
                .add_string_value ("call")
                .add_string_value (method)
                .begin_array ();
            foreach (var arg in args)
                request.add_value (arg);
            request
                .end_array ()
                .end_array ();
            string raw_request = Json.to_string (request.get_root (), false);

            bool waiting = false;

            // 创建待处理响应对象
            var pending = new PendingResponse (() => {
                if (waiting)
                    call.callback ();
                return false;
            });
            pending_responses[request_id] = pending;

            try {
                // 发送 RPC 消息
                yield peer.post_rpc_message (raw_request, data, cancellable);
            } catch (Error e) {
                if (pending_responses.unset (request_id))
                    pending.complete_with_error (e);
            }

            // 如果响应未完成，等待响应
            if (!pending.completed) {
                var cancel_source = new CancellableSource (cancellable);
                cancel_source.set_callback (() => {
                    if (pending_responses.unset (request_id))
                        pending.complete_with_error (new IOError.CANCELLED ("Operation was cancelled"));
                    return false;
                });
                cancel_source.attach (MainContext.get_thread_default ());

                waiting = true;
                yield;
                waiting = false;

                cancel_source.destroy ();
            }

            // 检查是否被取消
            cancellable.set_error_if_cancelled ();

            // 如果有错误，抛出错误
            if (pending.error != null)
                throw_api_error (pending.error);

            return pending.result;
        }

        // 尝试处理接收到的消息
        public bool try_handle_message (string json) {
            if (json.index_of ("\"frida:rpc\"") == -1)
                return false;

            var parser = new Json.Parser ();
            try {
                parser.load_from_data (json);
            } catch (GLib.Error e) {
                assert_not_reached ();
            }
            var message = parser.get_root ().get_object ();

            bool handled = false;

            var type = message.get_string_member ("type");
            if (type == "send")
                handled = try_handle_rpc_message (message);

            return handled;
        }

        // 尝试处理 RPC 消息
        private bool try_handle_rpc_message (Json.Object message) {
            var payload = message.get_member ("payload");
            if (payload == null || payload.get_node_type () != Json.NodeType.ARRAY)
                return false;
            var rpc_message = payload.get_array ();
            if (rpc_message.get_length () < 4)
                return false;

            string? type = rpc_message.get_element (0).get_string ();
            if (type == null || type != "frida:rpc")
                return false;

            var request_id_value = rpc_message.get_element (1);
            if (request_id_value.get_value_type () != typeof (string))
                return false;
            string request_id = request_id_value.get_string ();

            PendingResponse response;
            if (!pending_responses.unset (request_id, out response))
                return false;

            var status = rpc_message.get_string_element (2);
            if (status == "ok")
                response.complete_with_result (rpc_message.get_element (3));
            else
                response.complete_with_error (new Error.NOT_SUPPORTED (rpc_message.get_string_element (3)));

            return true;
        }

        // 内部类，表示待处理的响应
        private class PendingResponse {
            private SourceFunc? handler;

            // 表示响应是否已完成
            public bool completed {
                get {
                    return result != null || error != null;
                }
            }

            // 响应结果
            public Json.Node? result {
                get;
                private set;
            }

            // 响应错误
            public GLib.Error? error {
                get;
                private set;
            }

            // 构造函数，初始化 PendingResponse 对象
            public PendingResponse (owned SourceFunc handler) {
                this.handler = (owned) handler;
            }

            // 设置响应结果并调用处理函数
            public void complete_with_result (Json.Node result) {
                this.result = result;
                handler ();
                handler = null;
            }

            // 设置响应错误并调用处理函数
            public void complete_with_error (GLib.Error error) {
                this.error = error;
                handler ();
                handler = null;
            }
        }
    }

    // RpcPeer 接口，定义发送 RPC 消息的方法
    public interface RpcPeer : Object {
        public abstract async void post_rpc_message (string json, Bytes? data, Cancellable? cancellable) throws Error, IOError;
    }
}
