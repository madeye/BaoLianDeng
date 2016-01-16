package io.github.baoliandeng.core;

import android.util.Log;
import io.github.baoliandeng.tcpip.CommonMethods;
import io.github.baoliandeng.tunnel.Tunnel;

import java.io.IOException;
import java.net.InetSocketAddress;
import java.nio.channels.SelectionKey;
import java.nio.channels.Selector;
import java.nio.channels.ServerSocketChannel;
import java.nio.channels.SocketChannel;
import java.util.Iterator;

public class TcpProxyServer implements Runnable {

    public boolean Stopped;
    public short Port;

    Selector m_Selector;
    ServerSocketChannel m_ServerSocketChannel;
    Thread m_ServerThread;

    public TcpProxyServer(int port) throws IOException {
        m_Selector = Selector.open();
        m_ServerSocketChannel = ServerSocketChannel.open();
        m_ServerSocketChannel.configureBlocking(false);
        m_ServerSocketChannel.socket().bind(new InetSocketAddress(port));
        m_ServerSocketChannel.register(m_Selector, SelectionKey.OP_ACCEPT);
        this.Port = (short) m_ServerSocketChannel.socket().getLocalPort();
        Log.d(Constant.TAG, "AsyncTcpServer listen on " + (this.Port & 0xFFFF));
    }

    public synchronized void start() {
        m_ServerThread = new Thread(this);
        m_ServerThread.setName("TcpProxyServerThread");
        m_ServerThread.start();
    }

    public synchronized void stop() {
        this.Stopped = true;
        if (m_Selector != null) {
            try {
                m_Selector.close();
            } catch (Exception e) {
                Log.e(Constant.TAG, "Exception when closing m_Selector", e);
            } finally {
                m_Selector = null;
            }
        }

        if (m_ServerSocketChannel != null) {
            try {
                m_ServerSocketChannel.close();
            } catch (Exception e) {
                Log.e(Constant.TAG, "Exception when closing m_ServerSocketChannel", e);
            } finally {
                m_ServerSocketChannel = null;
            }
        }
    }

    @Override
    public void run() {
        try {
            while (true) {
                m_Selector.select();
                Iterator<SelectionKey> keyIterator = m_Selector.selectedKeys().iterator();
                while (keyIterator.hasNext()) {
                    SelectionKey key = keyIterator.next();
                    if (key.isValid()) {
                        try {
                            if (key.isReadable()) {
                                ((Tunnel) key.attachment()).onReadable(key);
                            } else if (key.isWritable()) {
                                ((Tunnel) key.attachment()).onWritable(key);
                            } else if (key.isConnectable()) {
                                ((Tunnel) key.attachment()).onConnectable();
                            } else if (key.isAcceptable()) {
                                onAccepted(key);
                            }
                        } catch (Exception e) {
                            Log.d(Constant.TAG, e.toString());
                        }
                    }
                    keyIterator.remove();
                }
            }
        } catch (Exception e) {
            Log.e(Constant.TAG, "TcpServer", e);
        } finally {
            this.stop();
            Log.d(Constant.TAG, "TcpServer thread exited.");
        }
    }

    InetSocketAddress getDestAddress(SocketChannel localChannel) {
        short portKey = (short) localChannel.socket().getPort();
        NatSession session = NatSessionManager.getSession(portKey);
        if (session != null) {
            if (ProxyConfig.Instance.needProxy(session.RemoteIP)) {
                if (ProxyConfig.IS_DEBUG)
                    Log.d(Constant.TAG, String.format("%d/%d:[PROXY] %s=>%s:%d", NatSessionManager.getSessionCount(),
                            Tunnel.SessionCount, session.RemoteHost,
                            CommonMethods.ipIntToString(session.RemoteIP), session.RemotePort & 0xFFFF));
                return InetSocketAddress.createUnresolved(session.RemoteHost, session.RemotePort & 0xFFFF);
            } else {
                return new InetSocketAddress(localChannel.socket().getInetAddress(), session.RemotePort & 0xFFFF);
            }
        }
        return null;
    }

    void onAccepted(SelectionKey key) {
        Tunnel localTunnel = null;
        try {
            SocketChannel localChannel = m_ServerSocketChannel.accept();
            localTunnel = TunnelFactory.wrap(localChannel, m_Selector);

            InetSocketAddress destAddress = getDestAddress(localChannel);
            if (destAddress != null) {
                Tunnel remoteTunnel = TunnelFactory.createTunnelByConfig(destAddress, m_Selector);
                remoteTunnel.setBrotherTunnel(localTunnel);
                localTunnel.setBrotherTunnel(remoteTunnel);
                remoteTunnel.connect(destAddress);
            } else {
                LocalVpnService.Instance.writeLog("Error: socket(%s:%d) target host is null.",
                        localChannel.socket().getInetAddress().toString(), localChannel.socket().getPort());
                localTunnel.dispose();
            }
        } catch (Exception e) {
            e.printStackTrace();
            LocalVpnService.Instance.writeLog("Error: remote socket create failed: %s", e.toString());
            if (localTunnel != null) {
                localTunnel.dispose();
            }
        }
    }

}
