#include "../../includes/channels.h"
#include "../../includes/protocol.h"
#include "../../includes/packet.h"
#include "../../includes/socket.h"
#include "../../includes/TCPPacket.h"
#include <Timer.h>

module TransportP{
	
	uses interface Timer<TMilli> as beaconTimer;

	uses interface SimpleSend as Sender;
	uses interface Forwarder;


	uses interface List<socket_t> as SocketList;
	uses interface List<pack> as PacketList;

	uses interface RoutingTable;

	provides interface Transport;
}
implementation{

	socket_t getSocket(uint8_t destPort, uint8_t srcPort);
	socket_t getServerSocket(uint8_t destPort);
	pack inFlight;

	event void beaconTimer.fired(){
	       pack p = inFlight;
	       tcpPacket* t = (tcpPacket*)(p.payload);
	       socket_t mySocket = getSocket(t->srcPort, t->destPort);
	       //dbg(TRANSPORT_CHANNEL, "IS THERE A SOCKET: %i\n", mySocket.src.port);
	       if(mySocket.dest.port){
		  dbg(TRANSPORT_CHANNEL, "PACKET DROPPED, RETRANSMITTING PACKET\n");
		  call SocketList.pushfront(mySocket);
		  call Transport.makePack(&p, TOS_NODE_ID, mySocket.dest.location, 15, 4, 0, t, 6);

		  call beaconTimer.startOneShot(140000);

		  call Sender.send(p, mySocket.dest.location); 
	       } 
	}

	socket_t getSocket(uint8_t destPort, uint8_t srcPort){
		bool foundSocket;
		socket_t mySocket;
		uint32_t i = 0;
		uint32_t size = call SocketList.size();
		for (i = 0; i < size; i++){
			mySocket = call SocketList.get(i);
			if(mySocket.dest.port == srcPort && mySocket.src.port == destPort && mySocket.CONN != LISTEN){
				foundSocket = TRUE;
				//call SocketList.remove(i);
				break;
			}
		}
		if(foundSocket)
			return mySocket;
		else
			dbg(TRANSPORT_CHANNEL, "Socket Not Found\n");

	}

	socket_t getServerSocket(uint8_t destPort){
		bool foundSocket;
		socket_t mySocket;
		uint16_t i = 0;
		uint16_t size = call SocketList.size();
		for(i = 0; i < size; i++){
			mySocket = call SocketList.get(i);
			if(mySocket.src.port == destPort && mySocket.CONN == LISTEN){
				foundSocket = TRUE;
				break;
			}
		}

		if(foundSocket)
			return mySocket;
		else
			dbg(TRANSPORT_CHANNEL, "Socket Not Found\n");
	}
	//Creates and packs our packet and send
	command error_t Transport.connect(socket_t fd){
		pack myMsg;
		tcpPacket* myTCPPack;
		myTCPPack = (tcpPacket*)(myMsg.payload);
		myTCPPack->destPort = fd.dest.port;
		myTCPPack->srcPort = fd.src.port;
		myTCPPack->ACK = 0;
		myTCPPack->seq = 1;
		myTCPPack->flag = SYN_FLAG;

		call Transport.makePack(&myMsg, TOS_NODE_ID, fd.dest.location, 15, 4, 0, myTCPPack, 6);
		fd.CONN = SYN_SENT;

		dbg(ROUTING_CHANNEL, "CLIENT TRYING \n");
		//Call sender.send which goes to fowarder.P
		call Sender.send(myMsg, fd.dest.location);

}	
	
	void connectDone(socket_t fd){
		pack myMsg;
		tcpPacket* myTCPPack;
		uint16_t i = 0;

	
		myTCPPack = (tcpPacket*)(myMsg.payload);
		myTCPPack->destPort = fd.dest.port;
		myTCPPack->srcPort = fd.src.port;
		myTCPPack->flag = DATA_FLAG;
		myTCPPack->seq = 0;

		i = 0;
		while(i < 6 && i <= fd.transfer){
			myTCPPack->payload[i] = i;
			i++;
		}

		myTCPPack->ACK = i;
		call Transport.makePack(&myMsg, TOS_NODE_ID, fd.dest.location, 15, 4, 0, myTCPPack, 6);

		call beaconTimer.startOneShot(140000);

		call Sender.send(myMsg, fd.dest.location);

}	

	command error_t Transport.receive(pack* msg){
		uint8_t srcPort = 0;
		uint8_t destPort = 0;
		uint8_t seq = 0;
		uint8_t ACKnum = 0;
		uint8_t flag = 0;
		uint16_t i = 0;
		uint16_t j = 0;
		socket_t mySocket;
		tcpPacket* myMsg = (tcpPacket *)(msg->payload);

		pack myNewMsg;
		tcpPacket* myTCPPack;

		srcPort = myMsg->srcPort;
		destPort = myMsg->destPort;
		seq = myMsg->seq;
		ACKnum = myMsg->ACK;
		flag = myMsg->flag;

		if(flag == SYN_FLAG || flag == SYN_ACK_FLAG || flag == ACK_FLAG){
			if(flag == SYN_FLAG){
				dbg(TRANSPORT_CHANNEL, "Got SYN! \n");
				mySocket = getServerSocket(destPort);
				if(mySocket.src.port && mySocket.CONN == LISTEN){
					mySocket.CONN = SYN_RCVD;
					mySocket.dest.port = srcPort;
					mySocket.dest.location = msg->src;
					call SocketList.pushfront(mySocket);
					myTCPPack = (tcpPacket *)(myNewMsg.payload);
					myTCPPack->destPort = mySocket.dest.port;
					myTCPPack->srcPort = mySocket.src.port;
					myTCPPack->seq = 1;
					myTCPPack->ACK = seq + 1;
					myTCPPack->flag = SYN_ACK_FLAG;
					dbg(TRANSPORT_CHANNEL, "Sending SYN ACK! - PAYLOAD SIZE = %i \n", 6);
					call Transport.makePack(&myNewMsg, TOS_NODE_ID, mySocket.dest.location, 15, 4, 0, myTCPPack, 6);
					call Sender.send(myNewMsg, mySocket.dest.location);
				}
			}

			else if(flag == SYN_ACK_FLAG){
				dbg(TRANSPORT_CHANNEL, "Got SYN ACK! \n");
				mySocket = getSocket(destPort, srcPort);
				if(mySocket.dest.port){
					mySocket.CONN = ESTABLISHED;
					call SocketList.pushfront(mySocket);
					myTCPPack = (tcpPacket*)(myNewMsg.payload);
					myTCPPack->destPort = mySocket.dest.port;
					myTCPPack->srcPort = mySocket.src.port;
					myTCPPack->seq = 1;
					myTCPPack->ACK = seq + 1;
					myTCPPack->flag = ACK_FLAG;
					dbg(TRANSPORT_CHANNEL, "SENDING ACK \n");
					call Transport.makePack(&myNewMsg, TOS_NODE_ID, mySocket.dest.location, 15, 4, 0, myTCPPack, 6);
					call Sender.send(myNewMsg, mySocket.dest.location);

					connectDone(mySocket);
				}
			}

			else if(flag == ACK_FLAG){
				dbg(TRANSPORT_CHANNEL, "GOT ACK \n");
				mySocket = getSocket(destPort, srcPort);
				if(mySocket.CONN == SYN_RCVD && mySocket.src.port){
					mySocket.CONN = ESTABLISHED;
					call SocketList.pushfront(mySocket);
				}
			}
		}

		if(flag == DATA_FLAG || flag == DATA_ACK_FLAG){

			if(flag == DATA_FLAG){
				dbg(TRANSPORT_CHANNEL, "RECEIVED DATA\n");
				mySocket = getSocket(destPort, srcPort);
				if(mySocket.CONN == ESTABLISHED && mySocket.src.port){
					myTCPPack = (tcpPacket*)(myNewMsg.payload);
					if(myMsg->payload[0] != 0 && mySocket.nextExp){
						i = mySocket.lastRCVD + 1;
						j = 0;
						while(j < myMsg->ACK){
							dbg(TRANSPORT_CHANNEL, "Writing to Receive Buffer: %d\n", i);
							mySocket.rcvdBuffer[i] = myMsg->payload[j];
							mySocket.lastRCVD = myMsg->payload[j];
							i++;
							j++;
						}
					}else if(seq == mySocket.nextExp){
						i = 0;
						while(i < myMsg->ACK){
							dbg(TRANSPORT_CHANNEL, "Writing to Receive Buffer: %d\n", i);
							mySocket.rcvdBuffer[i] = myMsg->payload[i];
							mySocket.lastRCVD = myMsg->payload[i];
							i++;
						}
					}
				//Window size is the socket buffer size - the last recieved mysocket +1
				mySocket.advertisedWindow = 64 - mySocket.lastRCVD + 1;
				mySocket.nextExp = seq + 1;
				call SocketList.pushfront(mySocket);
			
				myTCPPack->destPort = mySocket.dest.port;
				myTCPPack->srcPort = mySocket.src.port;
				myTCPPack->seq = seq;
				myTCPPack->ACK = seq + 1;
				myTCPPack->lastACKed = mySocket.lastRCVD;
				myTCPPack->advertisedWindow = mySocket.advertisedWindow;
				myTCPPack->flag = DATA_ACK_FLAG;
				dbg(TRANSPORT_CHANNEL, "SENDING DATA ACK FLAG\n");
				call Transport.makePack(&myNewMsg, TOS_NODE_ID, mySocket.dest.location, 15, 4, 0 , myTCPPack, 6);
				call Sender.send(myNewMsg, mySocket.dest.location);
				}
			} else if (flag == DATA_ACK_FLAG){
				dbg(TRANSPORT_CHANNEL, "RECEIVED DATA ACK, LAST ACKED: %d\n", myMsg->lastACKed);
				mySocket = getSocket(destPort, srcPort);
				if(mySocket.dest.port && mySocket.CONN == ESTABLISHED){
					if(myMsg->advertisedWindow != 0 && myMsg->lastACKed != mySocket.transfer){
						
						dbg(TRANSPORT_CHANNEL, "SENDING NEXT DATA\n");
						
						myTCPPack = (tcpPacket*)(myNewMsg.payload);
						
						i = myMsg->lastACKed + 1;
						j = 0;
						
						while(j < myMsg->advertisedWindow && j < 6 && i <= mySocket.transfer){
							
							dbg(TRANSPORT_CHANNEL, "Writing to Payload: %d\n", i);
							myTCPPack->payload[j] = i;
							i++;
							j++;
							
						}
					
						call SocketList.pushfront(mySocket);
						
						myTCPPack->flag = DATA_FLAG;
						
						myTCPPack->destPort = mySocket.dest.port;
						
						myTCPPack->srcPort = mySocket.src.port;
						
						myTCPPack->ACK = (i - 1) - myMsg->lastACKed;
						
						myTCPPack->seq = ACKnum;
						
						call Transport.makePack(&myNewMsg, TOS_NODE_ID, mySocket.dest.location, 15, 4, 0, myTCPPack, 6);
						
						
						call Transport.makePack(&inFlight, TOS_NODE_ID, mySocket.dest.location, 15, 4, 0, myTCPPack, 6);
						
						
						call beaconTimer.startOneShot(140000);
						call Sender.send(myNewMsg, mySocket.dest.location);
					}else{
						dbg(TRANSPORT_CHANNEL, "ALL DATA SENT, CLOSING CONNECTION\n");
						mySocket.CONN = FIN_WAIT1;
						call SocketList.pushfront(mySocket);
						myTCPPack = (tcpPacket*)(myNewMsg.payload);
						myTCPPack->destPort = mySocket.dest.port;
						myTCPPack->srcPort = mySocket.src.port;
						myTCPPack->seq = 1;
						myTCPPack->ACK = seq + 1;
						myTCPPack->flag = FIN_FLAG;
						call Transport.makePack(&myNewMsg, TOS_NODE_ID, mySocket.dest.location, 15, 4, 0, myTCPPack, 6);
						call Sender.send(myNewMsg, mySocket.dest.location);

					}
				}
			}
		}
		if(flag == FIN_FLAG || flag == FIN_ACK){
			if(flag == FIN_FLAG){
				dbg(TRANSPORT_CHANNEL, "GOT FIN FLAG \n");
				mySocket = getSocket(destPort, srcPort);
				if(mySocket.src.port){
					mySocket.CONN = CLOSED;
					mySocket.dest.port = srcPort;
					mySocket.dest.location = msg->src;

					myTCPPack = (tcpPacket *)(myNewMsg.payload);
					myTCPPack->destPort = mySocket.dest.port;
					myTCPPack->srcPort = mySocket.src.port;
					myTCPPack->seq = 1;
					myTCPPack->ACK = seq + 1;
					myTCPPack->flag = FIN_ACK;
					
					dbg(TRANSPORT_CHANNEL, "CONNECTION CLOSING, DATA RECEIVED: \n");

			                for(i = 0; i < mySocket.lastRCVD; i++){
				             dbg(TRANSPORT_CHANNEL, "%d\n", mySocket.rcvdBuffer[i]);
			                }

					call Transport.makePack(&myNewMsg, TOS_NODE_ID, mySocket.dest.location, 15, 4, 0, myTCPPack, 6);
					call Sender.send(myNewMsg, mySocket.dest.location);
				}
			}
			if(flag == FIN_ACK){
				dbg(TRANSPORT_CHANNEL, "GOT FIN ACK, CONNECTION IS CLOSED, GAME OVER\n");
				mySocket = getSocket(destPort, srcPort);
				if(mySocket.dest.port)
					mySocket.CONN = CLOSED;
			}
		}
}

	command void Transport.setTestServer(uint8_t src, uint8_t srcPort){

		socket_t mySocket;
		socket_addr_t myAddr;

		myAddr.location = src; //Previously TOS_NOD_ID

		myAddr.port = srcPort; //Changed to srcPort from 4 originally for project 4

		mySocket.src = myAddr;

		mySocket.CONN = LISTEN;

		mySocket.nextExp = 0; 

		call SocketList.pushfront(mySocket);
	}
	command void Transport.setTestClient(uint8_t src, uint8_t srcPort, uint8_t dest, uint8_t destPort){
		//Set test client and undergoe 3 way connection. Goes to transport.connect
		socket_t mySocket;
		socket_addr_t myAddr;

		uint8_t dest = dest;
		uint8_t srcPort = srcPort;
		uint8_t destPort = destPort;
		uint8_t transfer = 4000;

		myAddr.location = src;
		myAddr.port = srcPort;

		mySocket.dest.port = destPort;
		mySocket.dest.location = dest;
		mySocket.transfer = transfer;

		call SocketList.pushfront(mySocket);
		call Transport.connect(mySocket);
	}
	command void Transport.makePack(pack *Package, uint16_t src, uint16_t dest, uint16_t TTL, uint16_t protocol, uint16_t seq, uint8_t* payload, uint8_t length){
		Package->src = src;
		Package->dest = dest;
		Package->TTL = TTL;
		Package->seq = seq;
		Package->protocol = protocol;
		memcpy(Package->payload, payload, length);
}
}
