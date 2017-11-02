package io.github.baoliandeng.core;

import io.github.baoliandeng.tunnel.Config;
import io.github.baoliandeng.tunnel.RawTunnel;
import io.github.baoliandeng.tunnel.Tunnel;
import io.github.baoliandeng.tunnel.httpconnect.HttpConnectConfig;
import io.github.baoliandeng.tunnel.httpconnect.HttpConnectTunnel;

import java.net.InetSocketAddress;
import java.nio.channels.Selector;
import java.nio.channels.SocketChannel;

public class TunnelFactory {

    public static Tunnel wrap(SocketChannel channel, Selector selector) {
        return new RawTunnel(channel, selector);
    }

    public static Tunnel createTunnelByConfig(InetSocketAddress destAddress, Selector selector) throws Exception {
        if (destAddress.isUnresolved()) {
            Config config = ProxyConfig.Instance.getDefaultTunnelConfig(destAddress);
            if (config instanceof HttpConnectConfig) {
                return new HttpConnectTunnel((HttpConnectConfig) config, selector);
            }
            throw new Exception("The config is unknown.");
        } else {
            return new RawTunnel(destAddress, selector);
        }
    }

}
