package io.github.baoliandeng.tcpip;


public class TCPHeader {

    public static final int FIN = 1;
    public static final int SYN = 2;
    public static final int RST = 4;
    public static final int PSH = 8;
    public static final int ACK = 16;
    public static final int URG = 32;

    static final short offset_src_port = 0;
    static final short offset_dest_port = 2;
    static final int offset_seq = 4;
    static final int offset_ack = 8;
    static final byte offset_lenres = 12;
    static final byte offset_flag = 13;
    static final short offset_win = 14;
    static final short offset_crc = 16;
    static final short offset_urp = 18;

    public byte[] m_Data;
    public int m_Offset;

    public TCPHeader(byte[] data, int offset) {
        this.m_Data = data;
        this.m_Offset = offset;
    }

    public int getHeaderLength() {
        int lenres = m_Data[m_Offset + offset_lenres] & 0xFF;
        return (lenres >> 4) * 4;
    }

    public short getSourcePort() {
        return CommonMethods.readShort(m_Data, m_Offset + offset_src_port);
    }

    public void setSourcePort(short value) {
        CommonMethods.writeShort(m_Data, m_Offset + offset_src_port, value);
    }

    public short getDestinationPort() {
        return CommonMethods.readShort(m_Data, m_Offset + offset_dest_port);
    }

    public void setDestinationPort(short value) {
        CommonMethods.writeShort(m_Data, m_Offset + offset_dest_port, value);
    }

    public byte getFlags() {
        return m_Data[m_Offset + offset_flag];
    }

    public short getCrc() {
        return CommonMethods.readShort(m_Data, m_Offset + offset_crc);
    }

    public void setCrc(short value) {
        CommonMethods.writeShort(m_Data, m_Offset + offset_crc, value);
    }

    public int getSeqID() {
        return CommonMethods.readInt(m_Data, m_Offset + offset_seq);
    }

    public int getAckID() {
        return CommonMethods.readInt(m_Data, m_Offset + offset_ack);
    }

    @Override
    public String toString() {
        // TODO Auto-generated method stub
        return String.format("%s%s%s%s%s%s%d->%d %s:%s",
                (getFlags() & SYN) == SYN ? "SYN " : "",
                (getFlags() & ACK) == ACK ? "ACK " : "",
                (getFlags() & PSH) == PSH ? "PSH " : "",
                (getFlags() & RST) == RST ? "RST " : "",
                (getFlags() & FIN) == FIN ? "FIN " : "",
                (getFlags() & URG) == URG ? "URG " : "",
                getSourcePort() & 0xFFFF,
                getDestinationPort() & 0xFFFF,
                getSeqID(),
                getAckID());
    }
}
