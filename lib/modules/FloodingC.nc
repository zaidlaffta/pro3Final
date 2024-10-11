configuration FloodingC{
	provides interface SimpleSend;
	provides interface Receive as MainReceive;
}

implementation{
	components FloodingP;
	components new SimpleSendC(80);
	components new AMReceiverC(80);
	FloodingP.InternalSender -> SimpleSendC;
	FloodingP.InternalReceiver -> AMReceiverC;
	MainReceive = FloodingP.MainReceive;
	SimpleSend = FloodingP.FloodSender;
} 
