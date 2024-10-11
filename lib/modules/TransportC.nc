#define AM_TRANSPORT 66

configuration TransportC{
	provides interface Transport;
}

implementation{
	components TransportP;
	components new TimerMilliC() as beaconTimer;
	TransportP.beaconTimer -> beaconTimer;

	//components new TimerMilliC() as packetTimer;
	//TransportP.packetTimer -> packetTimer;

	components new SimpleSendC(AM_TRANSPORT);
	TransportP.Sender -> SimpleSendC;

	components new AMReceiverC(AM_TRANSPORT);

	Transport = TransportP.Transport;

	components RoutingTableC;
	TransportP.RoutingTable -> RoutingTableC.RoutingTable;

	components new ListC(socket_t, 64) as SocketList;
	TransportP.SocketList -> SocketList;
	
	components new ListC(pack, 64) as PacketListC;
    	TransportP.PacketList -> PacketListC;

	//components new QueueC(socket_t, 30) as socketQueue;
	//TransportP.socketQueue -> socketQueue;

	components ForwarderC;
	TransportP.Sender -> ForwarderC.SimpleSend;
	
}
