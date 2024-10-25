[CCode (gir_namespace = "FridaFruity", gir_version = "1.0")]
namespace Frida.Fruity {
	public interface NetworkStack : Object {
		public abstract InetAddress listener_ip {
			get;
		}

		public abstract uint scope_id {
			get;
		}

		public abstract async IOStream open_tcp_connection (InetSocketAddress address, Cancellable? cancellable)
			throws Error, IOError;
		public abstract UdpSocket create_udp_socket () throws Error;
	}

	public interface UdpSocket : Object {
		public abstract DatagramBased datagram_based {
			get;
		}

		public abstract void bind (InetSocketAddress address) throws Error;
		public abstract InetSocketAddress get_local_address () throws Error;
		public abstract void socket_connect (InetSocketAddress address, Cancellable? cancellable) throws Error;
	}

	public sealed class SystemNetworkStack : Object, NetworkStack {
		public InetAddress listener_ip {
			get {
				return _listener_ip;
			}
		}

		public uint scope_id {
			get {
				return _scope_id;
			}
		}

		private InetAddress _listener_ip;
		private uint _scope_id;

		public SystemNetworkStack (InetAddress listener_ip, uint scope_id) {
			_listener_ip = listener_ip;
			_scope_id = scope_id;
		}

		public async IOStream open_tcp_connection (InetSocketAddress address, Cancellable? cancellable) throws Error, IOError {
			return yield open_system_tcp_connection (address, cancellable);
		}

		public UdpSocket create_udp_socket () throws Error {
			return create_system_udp_socket ();
		}

		public static async IOStream open_system_tcp_connection (InetSocketAddress address, Cancellable? cancellable)
				throws Error, IOError {
			SocketConnection connection;
			try {
				var client = new SocketClient ();
				connection = yield client.connect_async (address, cancellable);
			} catch (GLib.Error e) {
				if (e is IOError.CONNECTION_REFUSED)
					throw new Error.SERVER_NOT_RUNNING ("%s", e.message);
				throw new Error.TRANSPORT ("%s", e.message);
			}

			Tcp.enable_nodelay (connection.socket);

			return connection;
		}

		public static UdpSocket create_system_udp_socket () throws Error {
			try {
				var handle = new Socket (IPV6, DATAGRAM, UDP);
				return new SystemUdpSocket (handle);
			} catch (GLib.Error e) {
				throw new Error.NOT_SUPPORTED ("%s", e.message);
			}
		}

		private class SystemUdpSocket : Object, UdpSocket {
			public Socket handle {
				get;
				construct;
			}

			public DatagramBased datagram_based {
				get {
					return handle;
				}
			}

			public SystemUdpSocket (Socket handle) {
				Object (handle: handle);
			}

			public void bind (InetSocketAddress address) throws Error {
				try {
					handle.bind (address, true);
				} catch (GLib.Error e) {
					throw new Error.NOT_SUPPORTED ("%s", e.message);
				}
			}

			public InetSocketAddress get_local_address () throws Error {
				try {
					return (InetSocketAddress) handle.get_local_address ();
				} catch (GLib.Error e) {
					throw new Error.NOT_SUPPORTED ("%s", e.message);
				}
			}

			public void socket_connect (InetSocketAddress address, Cancellable? cancellable) throws Error {
				try {
					handle.connect (address, cancellable);
				} catch (GLib.Error e) {
					throw new Error.TRANSPORT ("%s", e.message);
				}
			}
		}
	}

	public sealed class VirtualNetworkStack : Object, NetworkStack {
		public signal void outgoing_datagram (Bytes datagram);

		public Bytes? ethernet_address {
			get;
			construct;
		}

		public InetAddress? ipv6_address {
			get;
			construct;
		}

		public InetAddress listener_ip {
			get {
				return ipv6_address;
			}
		}

		public uint scope_id {
			get {
				return 0;
			}
		}

		public uint16 mtu {
			get;
			construct;
		}

		private State state = STARTED;

		private UnixInputStream input;
		private UnixOutputStream output;

		private Cancellable io_cancellable = new Cancellable ();

		private enum State {
			STARTED,
			STOPPED
		}

		public class VirtualNetworkStack (Bytes? ethernet_address, InetAddress? ipv6_address, uint16 mtu) {
			Object (
				ethernet_address: ethernet_address,
				ipv6_address: ipv6_address,
				mtu: mtu
			);
		}

		construct {
			var fd = Posix.open ("/dev/net/tun", Posix.O_RDWR);
			assert (fd != -1);

			input = new UnixInputStream (fd, true);
			output = new UnixOutputStream (fd, false);

			var req = Linux.Network.IfReq ();
			req.ifr_flags = Linux.If.IFF_TUN | Linux.If.IFF_NO_PI;
			Posix.strcpy ((string) req.ifr_name, "tun%d");

			var res = Linux.ioctl (fd, Linux.If.TUNSETIFF, &req);
			if (res == -1) {
				printerr ("TUNSETIFF failed: %s\n", Posix.strerror (errno));
				assert_not_reached ();
			}
			unowned string iface = (string) req.ifr_name;

			var netfd = Posix.socket (Linux.Socket.AF_NETLINK, Posix.SOCK_RAW | Linux.Socket.SOCK_CLOEXEC,
				Linux.Netlink.NETLINK_ROUTE);

			var nar = new NewAddrRequest (iface, ipv6_address);
			Posix.write (netfd, nar.data, nar.size);

			var nlur = new NewLinkUpRequest (iface);
			Posix.write (netfd, nlur.data, nlur.size);

			Posix.close (netfd);

			state = STARTED;

			process_outgoing_datagrams.begin ();
		}

		public override void dispose () {
			stop ();

			base.dispose ();
		}

		public void stop () {
			if (state == STOPPED)
				return;

			io_cancellable.cancel ();

			state = STOPPED;
		}

		public async IOStream open_tcp_connection (InetSocketAddress address, Cancellable? cancellable = null)
				throws Error, IOError {
			return yield SystemNetworkStack.open_system_tcp_connection (address, cancellable);
		}

		public UdpSocket create_udp_socket () throws Error {
			return SystemNetworkStack.create_system_udp_socket ();
		}

		public void handle_incoming_datagram (Bytes datagram) throws Error {
			try {
				output.write_all (datagram.get_data (), null);
			} catch (IOError e) {
				assert_not_reached ();
			}
		}

		private async void process_outgoing_datagrams () {
			try {
				while (true) {
					var datagram = yield input.read_bytes_async (2048, Priority.DEFAULT, io_cancellable);
					outgoing_datagram (datagram);
				}
			} catch (GLib.Error e) {
			}

			try {
				input.close ();
			} catch (IOError e) {
				assert_not_reached ();
			}
		}

		private class NewAddrRequest {
			public uint8[] data;
			public size_t size;

			public NewAddrRequest (string iface, InetAddress ip) {
				data = new uint8[sizeof (Linux.Netlink.NlMsgHdr) + sizeof (Linux.Network.IfAddrMsg) + 64];

				var header = (Linux.Netlink.NlMsgHdr *) data;
				header->nlmsg_len = Linux.Netlink.NLMSG_LENGTH ((int) sizeof (Linux.Network.IfAddrMsg));
				header->nlmsg_type = Linux.Netlink.RtMessageType.NEWADDR;
				header->nlmsg_flags = (uint16) (Linux.Netlink.NLM_F_REQUEST | Linux.Netlink.NLM_F_EXCL | Linux.Netlink.NLM_F_CREATE);

				var payload = (Linux.Network.IfAddrMsg *) (header + 1);
				payload->ifa_family = (uint8) Posix.AF_INET6;
				payload->ifa_prefixlen = 64;
				payload->ifa_index = Linux.Network.if_nametoindex (iface);

				var attr = Linux.Network.IFA_RTA (payload);
				attr->rta_len = (ushort) Linux.Netlink.RTA_LENGTH ((int) sizeof (Posix.In6Addr));
				attr->rta_type = Linux.Network.IfAddrType.ADDRESS;
				header->nlmsg_len += attr->rta_len;
				unowned uint8[] raw_ip = ip.to_bytes ();
				Memory.copy (Linux.Netlink.RTA_DATA (attr), raw_ip, sizeof (Posix.In6Addr));

				size = header->nlmsg_len;
			}
		}

		private class NewLinkUpRequest {
			public uint8[] data;
			public size_t size;

			public NewLinkUpRequest (string iface) {
				data = new uint8[sizeof (Linux.Netlink.NlMsgHdr) + sizeof (Linux.Netlink.IfInfoMsg)];

				var header = (Linux.Netlink.NlMsgHdr *) data;
				header->nlmsg_len = Linux.Netlink.NLMSG_LENGTH ((int) sizeof (Linux.Netlink.IfInfoMsg));
				header->nlmsg_type = Linux.Netlink.RtMessageType.NEWLINK;
				header->nlmsg_flags = (uint16) Linux.Netlink.NLM_F_REQUEST;

				var payload = (Linux.Netlink.IfInfoMsg *) (header + 1);
				payload->ifi_index = (int) Linux.Network.if_nametoindex (iface);
				payload->ifi_flags = Linux.Network.IfFlag.UP;
				payload->ifi_change = 1;

				size = header->nlmsg_len;
			}
		}
	}
}
