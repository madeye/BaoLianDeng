package io.github.baoliandeng.tunnel.httpconnect;

import io.github.baoliandeng.core.ProxyConfig;
import io.github.baoliandeng.tunnel.Tunnel;

import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.channels.Selector;

public class HttpConnectTunnel extends Tunnel {

    private boolean m_TunnelEstablished;
    private HttpConnectConfig m_Config;

    public HttpConnectTunnel(HttpConnectConfig config, Selector selector) throws IOException {
        super(config.ServerAddress, selector);
        m_Config = config;
    }

    @Override
    protected void onConnected(ByteBuffer buffer) throws Exception {
        String request = String.format("CONNECT %s:%d HTTP/1.0\r\nProxy-Connection: keep-alive\r\nUser-Agent: %s\r\nX-App-Install-ID: %s\r\n\r\n",
                m_DestAddress.getHostName(),
                m_DestAddress.getPort(),
                ProxyConfig.Instance.getUserAgent(),
                ProxyConfig.AppInstallID);

        buffer.clear();
        buffer.put(request.getBytes());
        buffer.flip();
        if (this.write(buffer, true)) {
            this.beginReceive();
        }
    }

    @Override
    protected void afterReceived(ByteBuffer buffer) throws Exception {
        if (!m_TunnelEstablished) {
            String response = new String(buffer.array(), buffer.position(), 12);
            if (response.matches("^HTTP/1.[01] 200$")) {
                buffer.limit(buffer.position());
            } else {
                throw new Exception(String.format("Proxy server responsed an error: %s", response));
            }

            m_TunnelEstablished = true;
            super.onTunnelEstablished();
        }
    }

    @Override
    protected boolean isTunnelEstablished() {
        return m_TunnelEstablished;
    }

    @Override
    protected void beforeSend(ByteBuffer buffer) throws Exception {
        // Nothing
    }

    @Override
    protected void onDispose() {
        m_Config = null;
    }


}
