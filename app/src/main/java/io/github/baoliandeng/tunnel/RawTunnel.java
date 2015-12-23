package io.github.baoliandeng.tunnel;

import java.net.InetSocketAddress;
import java.nio.ByteBuffer;
import java.nio.channels.Selector;
import java.nio.channels.SocketChannel;

public class RawTunnel extends Tunnel {

    public RawTunnel(InetSocketAddress serverAddress, Selector selector) throws Exception {
        super(serverAddress, selector);
    }

    public RawTunnel(SocketChannel innerChannel, Selector selector) {
        super(innerChannel, selector);
        // TODO Auto-generated constructor stub
    }

    @Override
    protected void onConnected(ByteBuffer buffer) throws Exception {
        onTunnelEstablished();
    }

    @Override
    protected void beforeSend(ByteBuffer buffer) throws Exception {
        // TODO Auto-generated method stub

    }

    @Override
    protected void afterReceived(ByteBuffer buffer) throws Exception {
        // TODO Auto-generated method stub

    }

    @Override
    protected boolean isTunnelEstablished() {
        return true;
    }

    @Override
    protected void onDispose() {
        // TODO Auto-generated method stub

    }

}
