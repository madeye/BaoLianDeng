package io.github.baoliandeng.tcpip;

import java.net.Inet4Address;
import java.net.InetAddress;
import java.net.UnknownHostException;

public class CommonMethods {

    public static InetAddress ipIntToInet4Address(int ip) {
        byte[] ipAddress = new byte[4];
        writeInt(ipAddress, 0, ip);
        try {
            return Inet4Address.getByAddress(ipAddress);
        } catch (UnknownHostException e) {
            // TODO Auto-generated catch block
            e.printStackTrace();
            return null;
        }
    }

    public static String ipIntToString(int ip) {
        return String.format("%s.%s.%s.%s", (ip >> 24) & 0x00FF,
                (ip >> 16) & 0x00FF, (ip >> 8) & 0x00FF, ip & 0x00FF);
    }

    public static String ipBytesToString(byte[] ip) {
        return String.format("%s.%s.%s.%s", ip[0] & 0x00FF, ip[1] & 0x00FF, ip[2] & 0x00FF, ip[3] & 0x00FF);
    }

    public static int ipStringToInt(String ip) {
        String[] arrStrings = ip.split("\\.");
        int r = (Integer.parseInt(arrStrings[0]) << 24)
                | (Integer.parseInt(arrStrings[1]) << 16)
                | (Integer.parseInt(arrStrings[2]) << 8)
                | Integer.parseInt(arrStrings[3]);
        return r;
    }

    public static int readInt(byte[] data, int offset) {
        int r = ((data[offset] & 0xFF) << 24)
                | ((data[offset + 1] & 0xFF) << 16)
                | ((data[offset + 2] & 0xFF) << 8) | (data[offset + 3] & 0xFF);
        return r;
    }

    public static short readShort(byte[] data, int offset) {
        int r = ((data[offset] & 0xFF) << 8) | (data[offset + 1] & 0xFF);
        return (short) r;
    }

    public static void writeInt(byte[] data, int offset, int value) {
        data[offset] = (byte) (value >> 24);
        data[offset + 1] = (byte) (value >> 16);
        data[offset + 2] = (byte) (value >> 8);
        data[offset + 3] = (byte) (value);
    }

    public static void writeShort(byte[] data, int offset, short value) {
        data[offset] = (byte) (value >> 8);
        data[offset + 1] = (byte) (value);
    }

    // �����ֽ�˳���������ֽ�˳���ת��

    public static short htons(short u) {
        int r = ((u & 0xFFFF) << 8) | ((u & 0xFFFF) >> 8);
        return (short) r;
    }

    public static short ntohs(short u) {
        int r = ((u & 0xFFFF) << 8) | ((u & 0xFFFF) >> 8);
        return (short) r;
    }

    public static int hton(int u) {
        int r = (u >> 24) & 0x000000FF;
        r |= (u >> 8) & 0x0000FF00;
        r |= (u << 8) & 0x00FF0000;
        r |= (u << 24) & 0xFF000000;
        return r;
    }

    public static int ntoh(int u) {
        int r = (u >> 24) & 0x000000FF;
        r |= (u >> 8) & 0x0000FF00;
        r |= (u << 8) & 0x00FF0000;
        r |= (u << 24) & 0xFF000000;
        return r;
    }

    // ����У���
    public static short checksum(long sum, byte[] buf, int offset, int len) {
        sum += getsum(buf, offset, len);
        while ((sum >> 16) > 0)
            sum = (sum & 0xFFFF) + (sum >> 16);
        return (short) ~sum;
    }

    public static long getsum(byte[] buf, int offset, int len) {
        long sum = 0; /* assume 32 bit long, 16 bit short */
        while (len > 1) {
            sum += readShort(buf, offset) & 0xFFFF;
            offset += 2;
            len -= 2;
        }

        if (len > 0) /* take care of left over byte */ {
            sum += (buf[offset] & 0xFF) << 8;
        }
        return sum;
    }

    // ����IP���У���
    public static boolean ComputeIPChecksum(IPHeader ipHeader) {
        short oldCrc = ipHeader.getCrc();
        ipHeader.setCrc((short) 0);// ����ǰ����
        short newCrc = CommonMethods.checksum(0, ipHeader.m_Data,
                ipHeader.m_Offset, ipHeader.getHeaderLength());
        ipHeader.setCrc(newCrc);
        return oldCrc == newCrc;
    }

    // ����TCP��UDP��У���
    public static boolean ComputeTCPChecksum(IPHeader ipHeader, TCPHeader tcpHeader) {
        ComputeIPChecksum(ipHeader);//����IPУ���
        int ipData_len = ipHeader.getTotalLength() - ipHeader.getHeaderLength();// IP��ݳ���
        if (ipData_len < 0)
            return false;
        // ����Ϊα�ײ���
        long sum = getsum(ipHeader.m_Data, ipHeader.m_Offset
                + IPHeader.offset_src_ip, 8);
        sum += ipHeader.getProtocol() & 0xFF;
        sum += ipData_len;

        short oldCrc = tcpHeader.getCrc();
        tcpHeader.setCrc((short) 0);// ����ǰ��0

        short newCrc = checksum(sum, tcpHeader.m_Data, tcpHeader.m_Offset, ipData_len);// ����У���

        tcpHeader.setCrc(newCrc);
        return oldCrc == newCrc;
    }

    // ����TCP��UDP��У���
    public static boolean ComputeUDPChecksum(IPHeader ipHeader, UDPHeader udpHeader) {
        ComputeIPChecksum(ipHeader);//����IPУ���
        int ipData_len = ipHeader.getTotalLength() - ipHeader.getHeaderLength();// IP��ݳ���
        if (ipData_len < 0)
            return false;
        // ����Ϊα�ײ���
        long sum = getsum(ipHeader.m_Data, ipHeader.m_Offset
                + IPHeader.offset_src_ip, 8);
        sum += ipHeader.getProtocol() & 0xFF;
        sum += ipData_len;

        short oldCrc = udpHeader.getCrc();
        udpHeader.setCrc((short) 0);// ����ǰ��0

        short newCrc = checksum(sum, udpHeader.m_Data, udpHeader.m_Offset, ipData_len);// ����У���

        udpHeader.setCrc(newCrc);
        return oldCrc == newCrc;
    }
}
