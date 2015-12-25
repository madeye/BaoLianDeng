package io.github.baoliandeng.tcpip;

import java.util.Locale;

public class IPHeader {

    public static final short IP = 0x0800;
    public static final byte ICMP = 1;
    public static final byte TCP = 6;
    public static final byte UDP = 17;
    public static final byte offset_proto = 9; // 9: Protocol
    public static final int offset_src_ip = 12; // 12: Source address
    public static final int offset_dest_ip = 16; // 16: Destination address
    static final byte offset_ver_ihl = 0; // 0: Version (4 bits) + Internet header length (4// bits)
    static final byte offset_tos = 1; // 1: Type of service
    static final short offset_tlen = 2; // 2: Total length
    static final short offset_identification = 4; // :4 Identification
    static final short offset_flags_fo = 6; // 6: Flags (3 bits) + Fragment offset (13 bits)
    static final byte offset_ttl = 8; // 8: Time to live
    static final short offset_crc = 10; // 10: Header checksum
    static final int offset_op_pad = 20; // 20: Option + Padding

    public byte[] m_Data;
    public int m_Offset;

    public IPHeader(byte[] data, int offset) {
        this.m_Data = data;
        this.m_Offset = offset;
    }

    public void Default() {
        setHeaderLength(20);
        setTos((byte) 0);
        setTotalLength(0);
        setIdentification(0);
        setFlagsAndOffset((short) 0);
        setTTL((byte) 64);
    }

    public int getDataLength() {
        return this.getTotalLength() - this.getHeaderLength();
    }

    public int getHeaderLength() {
        return (m_Data[m_Offset + offset_ver_ihl] & 0x0F) * 4;
    }

    public void setHeaderLength(int value) {
        m_Data[m_Offset + offset_ver_ihl] = (byte) ((4 << 4) | (value / 4));
    }

    public byte getTos() {
        return m_Data[m_Offset + offset_tos];
    }

    public void setTos(byte value) {
        m_Data[m_Offset + offset_tos] = value;
    }

    public int getTotalLength() {
        return CommonMethods.readShort(m_Data, m_Offset + offset_tlen) & 0xFFFF;
    }

    public void setTotalLength(int value) {
        CommonMethods.writeShort(m_Data, m_Offset + offset_tlen, (short) value);
    }

    public int getIdentification() {
        return CommonMethods.readShort(m_Data, m_Offset + offset_identification) & 0xFFFF;
    }

    public void setIdentification(int value) {
        CommonMethods.writeShort(m_Data, m_Offset + offset_identification, (short) value);
    }

    public short getFlagsAndOffset() {
        return CommonMethods.readShort(m_Data, m_Offset + offset_flags_fo);
    }

    public void setFlagsAndOffset(short value) {
        CommonMethods.writeShort(m_Data, m_Offset + offset_flags_fo, value);
    }

    public byte getTTL() {
        return m_Data[m_Offset + offset_ttl];
    }

    public void setTTL(byte value) {
        m_Data[m_Offset + offset_ttl] = value;
    }

    public byte getProtocol() {
        return m_Data[m_Offset + offset_proto];
    }

    public void setProtocol(byte value) {
        m_Data[m_Offset + offset_proto] = value;
    }

    public short getCrc() {
        return CommonMethods.readShort(m_Data, m_Offset + offset_crc);
    }

    public void setCrc(short value) {
        CommonMethods.writeShort(m_Data, m_Offset + offset_crc, value);
    }

    public int getSourceIP() {
        return CommonMethods.readInt(m_Data, m_Offset + offset_src_ip);
    }

    public void setSourceIP(int value) {
        CommonMethods.writeInt(m_Data, m_Offset + offset_src_ip, value);
    }

    public int getDestinationIP() {
        return CommonMethods.readInt(m_Data, m_Offset + offset_dest_ip);
    }

    public void setDestinationIP(int value) {
        CommonMethods.writeInt(m_Data, m_Offset + offset_dest_ip, value);
    }

    @Override
    public String toString() {
        return String.format(Locale.ENGLISH, "%s->%s Pro=%s,HLen=%d", CommonMethods.ipIntToString(getSourceIP()), CommonMethods.ipIntToString(getDestinationIP()), getProtocol(), getHeaderLength());
    }

}
