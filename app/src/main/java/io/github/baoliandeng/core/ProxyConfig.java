package io.github.baoliandeng.core;

import android.annotation.SuppressLint;
import io.github.baoliandeng.BuildConfig;
import io.github.baoliandeng.tcpip.CommonMethods;
import io.github.baoliandeng.tunnel.Config;
import io.github.baoliandeng.tunnel.httpconnect.HttpConnectConfig;

import java.net.InetSocketAddress;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.regex.Pattern;

public class ProxyConfig {
    public static final ProxyConfig Instance = new ProxyConfig();
    public final static boolean IS_DEBUG = BuildConfig.DEBUG;
    public final static int FAKE_NETWORK_MASK = CommonMethods.ipStringToInt("255.255.0.0");
    public final static int FAKE_NETWORK_IP = CommonMethods.ipStringToInt("26.25.0.0");
    public static String AppInstallID;
    public static String AppVersion;

    private static final String LOCAL_IP_ADDRESS = "(127[.]0[.]0[.]1)|" + "(localhost)|" +
        "(10[.]\\d{1,3}[.]\\d{1,3}[.]\\d{1,3})|" +
        "(172[.]((1[6-9])|(2\\d)|(3[01]))[.]\\d{1,3}[.]\\d{1,3})|" +
        "(192[.]168[.]\\d{1,3}[.]\\d{1,3})";
    private static Pattern localIpPattern = Pattern.compile(LOCAL_IP_ADDRESS);

    public static boolean isLocalIp(String ip) {
        return localIpPattern.matcher(ip).find();
    }

    ArrayList<IPAddress> m_IpList;
    ArrayList<IPAddress> m_DnsList;
    ArrayList<Config> m_ProxyList;
    HashMap<String, Boolean> m_DomainMap;

    int m_dns_ttl = 10;
    String m_welcome_info = "BaoLianDeng";
    String m_session_name = "BaoLianDeng";
    String m_user_agent = System.getProperty("http.agent");
    int m_mtu = 1500;


    public ProxyConfig() {
        m_IpList = new ArrayList<IPAddress>();
        m_DnsList = new ArrayList<IPAddress>();
        m_ProxyList = new ArrayList<Config>();
        m_DomainMap = new HashMap<String, Boolean>();

        m_IpList.add(new IPAddress("26.26.26.2", 32));
        m_DnsList.add(new IPAddress("114.114.114.114"));
        m_DnsList.add(new IPAddress("8.8.8.8"));

        Config config = HttpConnectConfig.parse("http://127.0.0.1:8787");
        if (!m_ProxyList.contains(config)) {
            m_ProxyList.add(config);
        }
    }

    public static boolean isFakeIP(int ip) {
        return (ip & ProxyConfig.FAKE_NETWORK_MASK) == ProxyConfig.FAKE_NETWORK_IP;
    }

    public Config getDefaultProxy() {
        return m_ProxyList.get(0);
    }

    public Config getDefaultTunnelConfig(InetSocketAddress destAddress) {
        return getDefaultProxy();
    }

    public IPAddress getDefaultLocalIP() {
        return m_IpList.get(0);
    }

    public ArrayList<IPAddress> getDnsList() {
        return m_DnsList;
    }

    public int getDnsTTL() {
        return m_dns_ttl;
    }

    public String getWelcomeInfo() {
        return m_welcome_info;
    }

    public String getSessionName() {
        return m_session_name;
    }

    public String getUserAgent() {
        return m_user_agent;
    }

    public int getMTU() {
        return m_mtu;
    }

    public void resetDomain(String[] items) {
        m_DomainMap.clear();
        addDomainToHashMap(items, 0, false);
    }

    private void addDomainToHashMap(String[] items, int offset, Boolean state) {
        for (int i = offset; i < items.length; i++) {
            String domainString = items[i].toLowerCase().trim();
            if (domainString.charAt(0) == '.') {
                domainString = domainString.substring(1);
            }
            m_DomainMap.put(domainString, state);
        }
    }

    private Boolean getDomainState(String domain) {
        domain = domain.toLowerCase();
        while (domain.length() > 0) {
            Boolean stateBoolean = m_DomainMap.get(domain);
            if (stateBoolean != null) {
                return stateBoolean;
            } else {
                int start = domain.indexOf('.') + 1;
                if (start > 0 && start < domain.length()) {
                    domain = domain.substring(start);
                } else {
                    return null;
                }
            }
        }
        return null;
    }

    public boolean needProxy(String host, int ip) {
        if (host != null) {
            Boolean stateBoolean = getDomainState(host);
            if (stateBoolean != null) {
                return stateBoolean.booleanValue();
            }
        }

        if (isFakeIP(ip))
            return true;

        if (ProxyConfig.isLocalIp(host))
            return false;

        if (ip != 0)
            return !ChinaIpMaskManager.isIPInChina(ip);

        return true;
    }


    public class IPAddress {
        public final String Address;
        public final int PrefixLength;

        public IPAddress(String address, int prefixLength) {
            this.Address = address;
            this.PrefixLength = prefixLength;
        }

        public IPAddress(String ipAddresString) {
            String[] arrStrings = ipAddresString.split("/");
            String address = arrStrings[0];
            int prefixLength = 32;
            if (arrStrings.length > 1) {
                prefixLength = Integer.parseInt(arrStrings[1]);
            }
            this.Address = address;
            this.PrefixLength = prefixLength;
        }

        @SuppressLint("DefaultLocale")
        @Override
        public String toString() {
            return String.format("%s/%d", Address, PrefixLength);
        }

        @Override
        public boolean equals(Object o) {
            if (o == null) {
                return false;
            } else {
                return this.toString().equals(o.toString());
            }
        }
    }

}
