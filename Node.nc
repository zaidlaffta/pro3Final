#include <Timer.h>
#include "includes/command.h"
#include "includes/packet.h"
#include "includes/CommandMsg.h"
#include "includes/sendInfo.h"
#include "includes/channels.h"
#include "includes/socket.h"
#include <string.h>

module Node{
   uses interface Boot;
   uses interface Timer<TMilli> as periodicTimer;
   uses interface Timer<TMilli> as periodicTimer1;
   uses interface Timer<TMilli> as TCP_Timer;
   uses interface Timer<TMilli> as TCP_Timeout;
   uses interface List<pack> as ListPackets;
   uses interface SplitControl as AMControl;
   uses interface Receive;
   uses interface SimpleSend as Sender;
   uses interface List<char> as NeighborList;
   uses interface CommandHandler;
   uses interface List<RouteNode> as RouteTable;
   uses interface List<ConnectedClients> as ClientsDB;
}

implementation{
   pack sendPackage;
   uint16_t seqNum = 0;
   socket_store_t sockets [MAX_NUM_OF_SOCKETS];
   socket_store_t s;
   uint8_t delay =0;
   uint8_t socket;
   uint16_t nextPacket = 0;
   uint8_t port_info [PACKET_MAX_PAYLOAD_SIZE];
   uint8_t clientPort;
   char *user;
   char *message;
   uint8_t instruction;
   // Prototypes
   void makePack(pack *Package, uint16_t src, uint16_t dest, uint16_t TTL, uint16_t Protocol, uint16_t seq, uint8_t *payload, uint8_t length);
   bool checkExistsPacket(pack *Package);
   void addPacketList(pack Package);
   void discoverNeighbors();
   void printNeighbors();
   void createRoutingTable();
   void printRoute();
   void send_syn(uint8_t srcPort, uint8_t dest_addr, uint8_t destPort);
   void send_rcvd(uint8_t srcPort, uint8_t dest_addr, uint8_t destPort);
   void send_TCP(uint8_t srcPort, uint8_t dest_addr, uint8_t destPort);
   uint16_t get_next_hop(uint16_t dest);

   event void Boot.booted(){
      call AMControl.start();

      dbg(GENERAL_CHANNEL, "Booted\n");
   }

   event void AMControl.startDone(error_t err){
      if(err == SUCCESS){
         call periodicTimer.startPeriodic(5000);
         dbg(GENERAL_CHANNEL, "Radio On\n");
      }else{
         //Retry if not successful
         call AMControl.start();
      }
   }

   event void AMControl.stopDone(error_t err){}
   event void periodicTimer.fired(){
      discoverNeighbors();
      if(delay > 5){
         createRoutingTable();
      }
      delay++;
   }
   event void periodicTimer1.fired(){
      createRoutingTable();
   }

   event void TCP_Timer.fired(){
      uint8_t i = 0; 
      uint8_t j = 0;
      for(i = 0; i < MAX_NUM_OF_SOCKETS; i++){
         if(sockets[i].state == SYN_SENT){
            send_syn(sockets[i].src, sockets[i].dest.addr, sockets[i].dest.port);
         }
         else if(sockets[i].state == SYN_RCVD){
            send_rcvd(sockets[i].src, sockets[i].dest.addr, sockets[i].dest.port);
         }
         else if(sockets[i].state == ESTABLISHED){
            //client
            if (sockets[i].flag == TOS_NODE_ID && nextPacket < 1){
               dbg(TRANSPORT_CHANNEL, "Timeout, retransmitting\n");
               sockets[i].nextExpected = nextPacket + sockets[i].effectiveWindow+1;
               send_TCP(sockets[i].src, sockets[i].dest.addr, sockets[i].dest.port);
            }
         }
      }
   }

   event void TCP_Timeout.fired(){
      uint8_t i = 0; 
      uint8_t j = 0;
      for(i = 0; i < MAX_NUM_OF_SOCKETS; i++){
         if(sockets[i].state == ESTABLISHED){
            if (sockets[i].flag == TOS_NODE_ID && nextPacket <= 1){
               dbg(TRANSPORT_CHANNEL, "Timeout called. Received up to %d packets for going from %d in port %d\n", sockets[i].lastAck, TOS_NODE_ID, sockets[i].src);
                  nextPacket = sockets[i].lastAck;
                     sockets[i].effectiveWindow = 1;
                  sockets[i].nextExpected = nextPacket + sockets[i].effectiveWindow;
               call TCP_Timeout.startOneShot( sockets[i].RTT * 2);
               send_TCP(sockets[i].src, sockets[i].dest.addr, sockets[i].dest.port);
               
            }
         }
      }
   }


   event message_t* Receive.receive(message_t* msg, void* payload, uint8_t len){
      if(len==sizeof(pack)){
         pack* myMsg=(pack*) payload;
         RouteNode *t = myMsg->payload;
         if(myMsg->TTL != 0 && checkExistsPacket(myMsg)==FALSE){
            if(myMsg->dest == AM_BROADCAST_ADDR){
               if(myMsg->protocol == PROTOCOL_PING){
                  makePack(&sendPackage, TOS_NODE_ID, AM_BROADCAST_ADDR, myMsg->TTL-1, PROTOCOL_PINGREPLY, seqNum, (uint8_t *) myMsg->payload, PACKET_MAX_PAYLOAD_SIZE);
                  addPacketList(sendPackage);
                  call Sender.send(sendPackage, myMsg->src);
               }
               else if(myMsg->protocol == PROTOCOL_PINGREPLY){
                  uint16_t i = 0;
                  bool found;
                  found = FALSE;

                  for(i=0; i < call NeighborList.size(); i++){
                     if(myMsg->src == call NeighborList.get(i)){
                        found = TRUE;
                     }
                  }
                  if(found ==FALSE){
                     
                     call NeighborList.pushback(myMsg->src);
                  }
               }
               else if(myMsg->protocol == PROTOCOL_LINKEDLIST){
                  RouteNode *r = (RouteNode *)myMsg->payload;
                  RouteNode rNode;
                  uint16_t i = 0;
                  uint16_t j = 0;
                  uint16_t k = 0;
                  char *message= "message to request for neighbor routing packets";
                  bool status = FALSE;
                  
                  for(i = 0; i < call RouteTable.size(); i++){
                     RouteNode temp1 = call RouteTable.get(i);
                     RouteNode *temp = &temp1;
                     if(temp->dest == r->dest){
                        
                        if(r->cost < temp->cost){
                           dbg(ROUTING_CHANNEL, "Found a better path. Taking: %d\n",myMsg->src);
                           temp1.cost = r->cost;
                           temp1.nextHop = myMsg->src;
                           call RouteTable.pushback(temp1);
                           call RouteTable.pop(i);
                        }
                        status = TRUE;
                     }
                  }
                  if(status == FALSE && r->dest != TOS_NODE_ID){
                     RouteNode temp;
                     temp.dest = r->dest;
                     temp.nextHop = myMsg->src;
                     temp.cost = (r->cost);
                     call RouteTable.pushback(temp);
                  }

                  for(j = i; j < call RouteTable.size();j++){
                     rNode = call RouteTable.get(j);
                     for(k = 0; k <=20; k++){
                        makePack(&sendPackage, TOS_NODE_ID, rNode.dest, MAX_TTL, PROTOCOL_LINKEDLIST, seqNum, (uint8_t *) message, PACKET_MAX_PAYLOAD_SIZE);
                        addPacketList(sendPackage);
                        seqNum = seqNum + 1;
                        if(rNode.nextHop <=20){
                           call Sender.send(sendPackage, rNode.nextHop);
                        }
                     }
                  }
               }
            }
            else if(TOS_NODE_ID == myMsg->dest){
               RouteNode rNode;
               RouteNode *rNode1;
               uint16_t i = 0;
               uint16_t j = 0;
               if (myMsg->protocol == PROTOCOL_SYN){
                  uint8_t i = 0;
                  uint16_t next;
                  uint8_t index;
                  uint8_t exists = 0;
                  ConnectedClients * temp = (ConnectedClients *)myMsg->payload;
                  ConnectedClients data;
                  index = temp->destPort;
                  user = temp->username;
                  for(i = 0; i < call ClientsDB.size();i++){
                     ConnectedClients t = call ClientsDB.get(i);
                     if((uint8_t) strcmp(t.username,temp->username) == 0){
                        exists = 1;
                     }
                  }
                  if(exists == 0){
                     data.username = user;
                     data.srcNode = temp->srcNode;
                     data.destPort = temp->srcPort;
                     call ClientsDB.pushback(data);
                  }
                  
                  if(sockets[index].state == LISTEN || sockets[index].state == ESTABLISHED){
                     //dbg(TRANSPORT_CHANNEL, "Syn Packet Arrived from Node %d for Port %d\n", myMsg->src, index);
                     if(sockets[index].state != ESTABLISHED){
                        sockets[index].state = SYN_RCVD;
                     }
                     sockets[index].src = TOS_NODE_ID;
                     sockets[index].dest.addr = temp->srcNode;
                     sockets[index].dest.port = temp->srcPort;
                     sockets[index].RTT = 4000;
                     send_rcvd(sockets[index].src, sockets[index].dest.addr, sockets[index].dest.port);
                  }
                  else{
                     dbg(TRANSPORT_CHANNEL, "state: %d\n", sockets[index].state);
                     dbg(TRANSPORT_CHANNEL, "Unable to open port because Server port was not open\n");
                  }
                  
               }
               else if (myMsg->protocol == PROTOCOL_SYN_ACK){
                  uint8_t index;
                  ConnectedClients * temp = (ConnectedClients *)myMsg->payload;
                  index = temp->destPort;
                  call TCP_Timer.stop();
                  sockets[index].state = ESTABLISHED;
                  sockets[index].effectiveWindow = 1;
                  dbg(TRANSPORT_CHANNEL, "TCP SUCCESSFULLY CONNECTED! Hello %s\n", temp->username);
                  if (sockets[index].flag == TOS_NODE_ID && nextPacket < 1){
                     sockets[index].nextExpected = nextPacket + sockets[index].effectiveWindow+1;
                     send_TCP(sockets[index].src, sockets[index].dest.addr, sockets[index].dest.port);
                  }
               
               }
               else if (myMsg->protocol == PROTOCOL_FIN){
                  uint8_t index;
                  index = myMsg->payload[0];
                  if(sockets[index].state == ESTABLISHED){
                     sockets[index].state = LISTEN;
                     dbg(TRANSPORT_CHANNEL, "Terminating server communication for node %d in port %d and changing state to LISTEN\n",TOS_NODE_ID, index);
                  }
                  else{
                     dbg(TRANSPORT_CHANNEL, "Cannot change state to LISTEN because server port was not created\n");
                  }
                  
               }
               else if (myMsg->protocol == PROTOCOL_TCP){
                  uint16_t next;
                  char *username;
                  uint8_t index;
                  ChatPackets *temp = (ChatPackets*) myMsg->payload;
                  ChatPackets data;
                  ChatPackets *data_address;
                  index = temp->destPort;
                  
                  if(sockets[temp->destPort].state == SYN_RCVD){
                     sockets[temp->destPort].state = ESTABLISHED;
                     data.srcPort = temp->destPort;
                     data.destPort = temp->srcPort;
                     data.seqNum = temp->seqNum;
                     data_address = &data;
                     

                     makePack(&sendPackage, TOS_NODE_ID, myMsg->src, MAX_TTL, PROTOCOL_ACK, seqNum, (uint8_t *)data_address, PACKET_MAX_PAYLOAD_SIZE);
                     next = get_next_hop(myMsg->src);
                     
                     call TCP_Timer.startOneShot(sockets[temp->destPort].RTT * 2);
                     call Sender.send(sendPackage, next);
                  }
                  else if(temp->info == 1){
                     uint8_t i =0;

                     for(i = 0; i < call ClientsDB.size(); i++){
                        ConnectedClients t = call ClientsDB.get(i);
                        if(t.srcNode != myMsg->src){
                           data.destPort = t.destPort;
                           data.srcPort = temp->destPort;
                           data.seqNum = temp->seqNum;
                           data.message = temp->message;
                           data.username = temp->username;
                          
                           data.info = temp->info;
                           data_address = &data;
                           makePack(&sendPackage, TOS_NODE_ID, t.srcNode, MAX_TTL, PROTOCOL_ACK, seqNum, (uint8_t *)data_address, PACKET_MAX_PAYLOAD_SIZE);
                           next = get_next_hop(t.srcNode);
                          
                           call TCP_Timer.startOneShot(sockets[temp->destPort].RTT * 2);
                           call Sender.send(sendPackage, next);
                        }
                     }
                  }
                   else if(temp->info == 2){
                     uint8_t i =0;
                     char *names = temp->username;
                     char *usr = strtok(names, " ");
                     char *receiver = strtok(NULL, "\n");
                     
                     for(i = 0; i < call ClientsDB.size(); i++){
                        ConnectedClients t = call ClientsDB.get(i);
                        if(t.srcNode != myMsg->src && strcmp(t.username, receiver) ==  0){
                           data.destPort = t.destPort;
                           data.srcPort = temp->destPort;
                           data.seqNum = temp->seqNum;
                           data.message = temp->message;
                           data.username = temp->username;
                          
                           data.info = temp->info;
                           data_address = &data;
                           
                           makePack(&sendPackage, TOS_NODE_ID, t.srcNode, MAX_TTL, PROTOCOL_ACK, seqNum, (uint8_t *)data_address, PACKET_MAX_PAYLOAD_SIZE);
                           next = get_next_hop(t.srcNode);
                           
                           call Sender.send(sendPackage, next);
                        }
                     }
                  }
                  else if(temp->info == 3){
                     uint8_t i =0;
                     strcpy(temp->message, "listUsrRply ");

                     for(i = 0; i < call ClientsDB.size(); i++){
                        ConnectedClients t = call ClientsDB.get(i);
                        strcat(temp->message, t.username);
                        
                        if(i == (call ClientsDB.size())-1){
                           strcat(temp->message, "\n");
                        }
                        else{
                        strcat(temp->message, ", ");
                        }
                        
                     }

                     for(i = 0; i < call ClientsDB.size(); i++){
                        ConnectedClients t = call ClientsDB.get(i);
                        if(strcmp(t.username, temp->username) == 0){
                           data.destPort = t.destPort;
                           data.srcPort = temp->destPort;
                           data.seqNum = temp->seqNum;
                           data.message = temp->message;
                           data.username = temp->username;
                           data.info = temp->info;
                           data_address = &data;
                           
                           makePack(&sendPackage, TOS_NODE_ID, t.srcNode, MAX_TTL, PROTOCOL_ACK, seqNum, (uint8_t *)data_address, PACKET_MAX_PAYLOAD_SIZE);
                           next = get_next_hop(t.srcNode);
                           
                           call Sender.send(sendPackage, next);
                        }
                     }
                  }
                  else{
                     data.srcPort = temp->destPort;
                     data.destPort = temp->srcPort;
                     data.seqNum = temp->seqNum;
                     data_address = &data;
                     
                     makePack(&sendPackage, TOS_NODE_ID, myMsg->src, MAX_TTL, PROTOCOL_ACK, seqNum, (uint8_t *)data_address, PACKET_MAX_PAYLOAD_SIZE);
                     next = get_next_hop(myMsg->src);
                     
                     call TCP_Timer.startOneShot(sockets[temp->destPort].RTT * 2);
                     call Sender.send(sendPackage, next);
                  }
               }
               else if (myMsg->protocol == PROTOCOL_ACK){
                   uint8_t k = 0;
                   ChatPackets *temp = (ChatPackets*) myMsg->payload;
                   call TCP_Timer.stop();
                  
                  if(temp->info == 1){
                     dbg(TRANSPORT_CHANNEL, "%s BROADCASTED the message: %s\n", temp->username, temp->message);
                  }
                  else if(temp->info == 2){
                     dbg(TRANSPORT_CHANNEL, "%s UNICASTED the message: %s\n", temp->username, temp->message);
                  }
                  else if(temp->info == 3){
                     dbg(TRANSPORT_CHANNEL, "%s sent client list: %s\n", temp->username, temp->message);
                  }
                  if(sockets[temp->destPort].effectiveWindow < 1){
                     sockets[temp->destPort].effectiveWindow++;
                     
                  }
                  if(temp->seqNum - sockets[temp->destPort].lastAck == 1){
                     sockets[temp->destPort].lastAck = temp->seqNum;
                  }
               }

               else if (myMsg->protocol == PROTOCOL_LINKEDLIST){
                  RouteNode rNode2;
                  for(i = 0; i < call RouteTable.size(); i++){
                     rNode = call RouteTable.get(i);
                     if(rNode.cost != 20){
                        rNode.cost = rNode.cost + 1;
                     }
                     rNode1 = &rNode;
                     makePack(&sendPackage, TOS_NODE_ID, myMsg->src, MAX_TTL, PROTOCOL_PINGREPLY, seqNum, (uint8_t *) rNode1, PACKET_MAX_PAYLOAD_SIZE);
                     addPacketList(sendPackage);
                     seqNum = seqNum + 1;
                     for(j = i; j < call RouteTable.size(); j++){
                        rNode2 = call RouteTable.get(j);
                        if((uint16_t)myMsg->src == (uint16_t) rNode2.dest){
                           break;
                        }
                     }
                     call Sender.send(sendPackage, rNode2.nextHop);
                  }
               }
               else if(myMsg->protocol == PROTOCOL_PINGREPLY){
                  RouteNode *r = (RouteNode *) myMsg->payload;
                  uint16_t i = 0;
                  bool status = FALSE;
                  for(i = 0; i < call RouteTable.size(); i++){
                     RouteNode temp1 = call RouteTable.get(i);
                     RouteNode *temp = &temp1;
                     if(temp->dest == r->dest){
                        if(r->cost < temp->cost){
                           temp1.cost = r->cost;
                           temp1.nextHop = myMsg->src;
                           call RouteTable.pushback(temp1);
                           call RouteTable.pop(i);
                        }
                        status = TRUE;
                     }
                  }
                  if(status == FALSE && r->dest != TOS_NODE_ID){
                     RouteNode temp;
                     temp.dest = r->dest;
                     temp.nextHop = myMsg->src;
                     temp.cost = (r->cost);
                     call RouteTable.pushback(temp);
                  }
                
               }
               else if (myMsg->protocol == PROTOCOL_PING){

                  dbg(ROUTING_CHANNEL, "Packet has arrived! %s\n", myMsg->payload);
               } 
            }
            else{
               
               if(myMsg->protocol == PROTOCOL_LINKEDLIST){
                  uint i = 0;
                  RouteNode r;
                  
                  for (i = 0; i < call RouteTable.size(); i++){
                     r = call RouteTable.get(i);
                     if((uint16_t)myMsg->dest == (uint16_t)r.dest){
                        makePack(&sendPackage, myMsg->src, myMsg->dest, myMsg->TTL-1, PROTOCOL_LINKEDLIST, seqNum, (uint8_t *) myMsg->payload, PACKET_MAX_PAYLOAD_SIZE);
                        seqNum++;
                        addPacketList(sendPackage);
                        if(r.nextHop < 25){
                           dbg(ROUTING_CHANNEL, "REROUTING for the ping event from %d to %d\n",TOS_NODE_ID, r.nextHop);
                           call Sender.send(sendPackage, r.nextHop);
                        }
                        break;
                     }
                  }
                  
                  if(i == call RouteTable.size()){
                     dbg(GENERAL_CHANNEL, "No Path Found\n");
                  }
               }
               
               else if(myMsg->protocol == PROTOCOL_PING){
                  seqNum++;
                  makePack(&sendPackage, myMsg->src, myMsg->dest, myMsg->TTL-1, PROTOCOL_PING, seqNum, (uint8_t *) myMsg->payload, PACKET_MAX_PAYLOAD_SIZE);
                  addPacketList(sendPackage);
                  
                     dbg(ROUTING_CHANNEL, "REROUTING for the ping event from %d to %d\n",TOS_NODE_ID, get_next_hop(myMsg->dest));
                     call Sender.send(sendPackage, get_next_hop(myMsg->dest));
                  
               }
               else if(myMsg->protocol == PROTOCOL_SYN){
                  seqNum++;
                  makePack(&sendPackage, myMsg->src, myMsg->dest, myMsg->TTL-1, PROTOCOL_SYN, seqNum, (uint8_t *) myMsg->payload, PACKET_MAX_PAYLOAD_SIZE);
                  addPacketList(sendPackage);

                     dbg(ROUTING_CHANNEL, "REROUTING for the ping event from %d to %d\n",TOS_NODE_ID, get_next_hop(myMsg->dest));
                     call Sender.send(sendPackage, get_next_hop(myMsg->dest));
                  
               }
               else if (myMsg->protocol == PROTOCOL_FIN){
                  seqNum++;
                  makePack(&sendPackage, myMsg->src, myMsg->dest, myMsg->TTL-1, PROTOCOL_FIN, seqNum, (uint8_t *) myMsg->payload, PACKET_MAX_PAYLOAD_SIZE);
                  addPacketList(sendPackage);
                  
                     dbg(ROUTING_CHANNEL, "REROUTING for the ping event from %d to %d\n",TOS_NODE_ID, get_next_hop(myMsg->dest));
                     call Sender.send(sendPackage, get_next_hop(myMsg->dest));
                  
               }
               else if(myMsg->protocol == PROTOCOL_SYN_ACK){
                  seqNum++;
                  makePack(&sendPackage, myMsg->src, myMsg->dest, myMsg->TTL-1, PROTOCOL_SYN_ACK, seqNum, (uint8_t *) myMsg->payload, PACKET_MAX_PAYLOAD_SIZE);
                  
                  addPacketList(sendPackage);
                  
                     dbg(ROUTING_CHANNEL, "REROUTING for the ping event from %d to %d\n",TOS_NODE_ID, get_next_hop(myMsg->dest));
                     call Sender.send(sendPackage, get_next_hop(myMsg->dest));
                  
               }
               else if(myMsg->protocol == PROTOCOL_TCP){
                  seqNum++;
                  makePack(&sendPackage, myMsg->src, myMsg->dest, myMsg->TTL-1, PROTOCOL_TCP, seqNum, (uint8_t *) myMsg->payload, PACKET_MAX_PAYLOAD_SIZE);
                  
                  addPacketList(sendPackage);
                  
                     dbg(ROUTING_CHANNEL, "REROUTING for the ping event from %d to %d\n",TOS_NODE_ID, get_next_hop(myMsg->dest));
                     call Sender.send(sendPackage, get_next_hop(myMsg->dest));
                  
               }
               else if(myMsg->protocol == PROTOCOL_ACK){
                  seqNum++;
                  makePack(&sendPackage, myMsg->src, myMsg->dest, myMsg->TTL-1, PROTOCOL_ACK, seqNum, (uint8_t *) myMsg->payload, PACKET_MAX_PAYLOAD_SIZE);
                 
                  addPacketList(sendPackage);
                  
                     dbg(ROUTING_CHANNEL, "REROUTING for the ping event from %d to %d\n",TOS_NODE_ID, get_next_hop(myMsg->dest));
                     call Sender.send(sendPackage, get_next_hop(myMsg->dest));
                  
               }
            }
         }
         return msg;
      }
      dbg(GENERAL_CHANNEL, "Unknown Packet Type %d\n", len);
      return msg;
   }


   event void CommandHandler.ping(uint16_t destination, uint8_t *payload){
      uint i = 0;
      RouteNode r;
      dbg(GENERAL_CHANNEL, "PING EVENT \n");
      dbg(GENERAL_CHANNEL, "Packet source %d\n", TOS_NODE_ID);
      
      for (i = 0; i < call RouteTable.size(); i++){
         r = call RouteTable.get(i);
         if((destination == (uint16_t) r.dest) && r.cost < 20){
            dbg(ROUTING_CHANNEL, "Found a route!!! %d\n", r.nextHop);
            makePack(&sendPackage, TOS_NODE_ID, destination, MAX_TTL, PROTOCOL_PING, seqNum, payload, PACKET_MAX_PAYLOAD_SIZE);
            seqNum++;
            addPacketList(sendPackage);
            call Sender.send(sendPackage, r.nextHop);
            break;
         }
      }
      if(i == call RouteTable.size()){
         dbg(GENERAL_CHANNEL, "No Path Found\n");
      }
   }

   event void CommandHandler.printNeighbors(){}

   event void CommandHandler.printRouteTable(){}

   event void CommandHandler.printLinkState(){}

   event void CommandHandler.printDistanceVector(){}

   event void CommandHandler.setTestServer(uint8_t socket_in){
      sockets[socket_in].state = LISTEN;
   }

   event void CommandHandler.setTestClient(uint16_t source_socket, uint16_t target_addr, uint16_t target_socket, uint8_t * data){
      sockets[source_socket].state = SYN_SENT;
      sockets[source_socket].flag = TOS_NODE_ID;
      sockets[source_socket].src = source_socket;
      sockets[source_socket].dest.addr = target_addr;
      sockets[source_socket].dest.port = target_socket;
      user = (char *) data;
      
      sockets[source_socket].RTT = 4000;
      
      send_syn(source_socket, target_addr, target_socket);
   }

   event void CommandHandler.setClientClose(uint8_t client_addr, uint8_t dest_addr, uint8_t destPort, uint8_t srcPort){
      uint16_t nexHop = get_next_hop(dest_addr);
      sockets[srcPort].state = CLOSED;
      port_info[0] = destPort;
      
      makePack(&sendPackage, TOS_NODE_ID, dest_addr, MAX_TTL, PROTOCOL_FIN, seqNum, (uint8_t *) port_info, PACKET_MAX_PAYLOAD_SIZE);
      call Sender.send(sendPackage, nexHop);
   }

   event void CommandHandler.setAppServer(uint8_t server, uint8_t port){
      sockets[port].state = LISTEN;
   }

   event void CommandHandler.setAppClient(uint8_t client, uint8_t *payload){
      char *res = payload;
      char *delimiter = " \n";
      char *res1 = strtok(res, delimiter);
      

      if((uint8_t) strcmp(res1,"hello") == 0){
         char *clientport;
         uint8_t port;
         user = strtok(NULL, delimiter);
         
         clientport = strtok(NULL, delimiter);
         
         port = atoi(clientport);
         clientPort = port;
         instruction = 0;
         message = res;
         
         signal CommandHandler.setTestClient(port, 1, 1, user);
      }
      else if((uint8_t) strcmp(res1,"msg") == 0){
         message = strtok(NULL, "\n");
        
         instruction = 1;
         
         send_TCP(clientPort,1,1);
      }
      else if((uint8_t) strcmp(res1,"whisper") == 0){
          char *receiver = strtok(NULL, delimiter);
          
          strcat(user, " ");
          strcat(user, receiver);
          instruction = 2;
          message = strtok(NULL, "\n");
          

          send_TCP(clientPort,1,1);
      }
      else if((uint8_t) strcmp(res1,"listusr") == 0){
         instruction = 3;
         send_TCP(clientPort,1,1);
      }
      else{
         dbg(TRANSPORT_CHANNEL,"%s is not an option\n", res1);
      }
      
   }

   void makePack(pack *Package, uint16_t src, uint16_t dest, uint16_t TTL, uint16_t protocol, uint16_t seq, uint8_t* payload, uint8_t length){
      Package->src = src;
      Package->dest = dest;
      Package->TTL = TTL;
      Package->seq = seq;
      Package->protocol = protocol;
      memcpy(Package->payload, payload, length);
   }
   bool checkExistsPacket(pack *Package){
      uint16_t size = call ListPackets.size();
      uint16_t i = 0;
      pack p;
      for(i = 0; i < size; i++){
         p = call ListPackets.get(i);
         if(p.src == Package->src && p.dest == Package->dest && p.seq == Package->seq){
            return TRUE;
         }
      }
      return FALSE;
   }
   void addPacketList(pack Package){
      if(call ListPackets.isFull() == TRUE){
         call ListPackets.popfront();
      }
      call ListPackets.pushback(Package);
   }
   void discoverNeighbors(){
      char *message ="FindNeighbors\n";
      pack packet;
      seqNum++;
      makePack(&packet, TOS_NODE_ID, AM_BROADCAST_ADDR, 2, PROTOCOL_PING, seqNum, (uint8_t*) message, PACKET_MAX_PAYLOAD_SIZE);
      addPacketList(packet);
      
      call Sender.send(packet, AM_BROADCAST_ADDR);
   }
   
   void printNeighbors(){
      uint16_t i, size;
		size = call NeighborList.size();
		if(size == 0) {
			dbg(NEIGHBOR_CHANNEL, "No Neighbors found\n");
		} 
      else {
			dbg(NEIGHBOR_CHANNEL, "Printing Neighbors:");
			for(i = 0; i < size; i++) {
				char neighbors = call NeighborList.get(i);
				dbg(NEIGHBOR_CHANNEL, "Neighbor: %d\n", neighbors);
			}
		}
   }
   
   void createRoutingTable(){
      uint16_t i = 0;
      RouteNode rNode;
      RouteNode *rNode1;
      if(call RouteTable.size() == 0){
         rNode.dest = TOS_NODE_ID;
         rNode.nextHop = TOS_NODE_ID;
         rNode.cost = 0;
         call RouteTable.pushback(rNode);
         dbg(ROUTING_CHANNEL, "Creating table for: %d\n", TOS_NODE_ID);
         for(i = 0; i < call NeighborList.size(); i++){
            if(call NeighborList.get(i) != (char) TOS_NODE_ID){
               rNode.dest = call NeighborList.get(i);
               rNode.nextHop = call NeighborList.get(i);
               rNode.cost = 1;
               call RouteTable.pushback(rNode);
            }
         }
      }
      for(i = 0; i < call RouteTable.size(); i++){
         rNode = call RouteTable.get(i);
         rNode.cost = rNode.cost + 1;
         if(rNode.dest != TOS_NODE_ID){
            rNode1 = &rNode;
            makePack(&sendPackage, TOS_NODE_ID, AM_BROADCAST_ADDR, MAX_TTL, PROTOCOL_LINKEDLIST, seqNum, (uint8_t *) rNode1, PACKET_MAX_PAYLOAD_SIZE);
            addPacketList(sendPackage);
            seqNum = seqNum + 1;
            call Sender.send(sendPackage, AM_BROADCAST_ADDR);
         }
      }   
   }
   
   void printRoute(){
      uint16_t i,size;
      RouteNode temp1;
		size = call RouteTable.size();
      dbg(TRANSPORT_CHANNEL, "Getting Route for: %d\n", TOS_NODE_ID);
		if(size == 0) {
			dbg(ROUTING_CHANNEL, "No Routing found\n");
		} 
      else {
         dbg(TRANSPORT_CHANNEL, "dest | nextHop | cost\n");
			for(i = 0; i < call RouteTable.size(); i++) {
				temp1 = call RouteTable.get(i);
            dbg(TRANSPORT_CHANNEL, "%d | %d | %d\n", temp1.dest, temp1.nextHop, temp1.cost);
			}
		}
   }

  
   void send_syn(uint8_t srcPort, uint8_t dest_addr, uint8_t destPort){
      ConnectedClients data;
      ConnectedClients * data_address;
      uint16_t nexHop = get_next_hop(dest_addr);
      
      data.username = user;
      data.srcPort = srcPort;
      data.destPort = destPort;
      data.srcNode = TOS_NODE_ID;
      data_address = &data;
     
      makePack(&sendPackage, TOS_NODE_ID, dest_addr, MAX_TTL, PROTOCOL_SYN, seqNum, (uint8_t *) data_address, PACKET_MAX_PAYLOAD_SIZE);
      addPacketList(sendPackage);
      seqNum++;
      if(nexHop < 25){
         call TCP_Timer.startOneShot(sockets[srcPort].RTT * 2);
         call Sender.send(sendPackage, nexHop);
      }
   }
   void send_rcvd(uint8_t srcPort, uint8_t dest_addr, uint8_t destPort){
      ConnectedClients data;
      ConnectedClients * data_address;
      uint16_t nexHop = get_next_hop(dest_addr);
      
      data.srcPort = srcPort;
      data.destPort = destPort;
      data.username = user;
      data.srcNode = TOS_NODE_ID;
      data_address = &data;
      makePack(&sendPackage, TOS_NODE_ID, dest_addr, MAX_TTL, PROTOCOL_SYN_ACK, seqNum, (uint8_t *) data_address, PACKET_MAX_PAYLOAD_SIZE);
      addPacketList(sendPackage);
      seqNum++;
      if(nexHop < 25){
         call TCP_Timer.startOneShot(sockets[srcPort].RTT * 2);
         
         call Sender.send(sendPackage, nexHop);
      }
   }
   
   void send_TCP(uint8_t srcPort, uint8_t dest_addr, uint8_t destPort){
         ChatPackets data;
         ChatPackets *data_address;
         uint16_t nexHop = get_next_hop(dest_addr);
         
         if(instruction == 1){
            
            nextPacket++;
            data.srcPort = srcPort;
            data.destPort = destPort;
            data.seqNum = nextPacket;
            data.info = instruction;
            data.username = user;
            data.message = message;
            data_address = &data;
            
            makePack(&sendPackage, TOS_NODE_ID, dest_addr, MAX_TTL, PROTOCOL_TCP, seqNum, (uint8_t *) data_address, PACKET_MAX_PAYLOAD_SIZE);
            
            sockets[srcPort].effectiveWindow--;
            
            call TCP_Timer.startOneShot(sockets[srcPort].RTT * 2);
            call Sender.send(sendPackage, nexHop);
         }
         if(instruction == 2){
            
            nextPacket++;
            data.srcPort = srcPort;
            data.destPort = destPort;
            data.seqNum = nextPacket;
            data.info = instruction;
            data.username = user;
            
            data.message = message;
            data_address = &data;

            
            makePack(&sendPackage, TOS_NODE_ID, dest_addr, MAX_TTL, PROTOCOL_TCP, seqNum, (uint8_t *) data_address, PACKET_MAX_PAYLOAD_SIZE);
            
            sockets[srcPort].effectiveWindow--;
            
            call TCP_Timer.startOneShot(sockets[srcPort].RTT * 2);
            call Sender.send(sendPackage, nexHop);
         }
         if(instruction == 3){
            
            nextPacket++;
            data.srcPort = srcPort;
            data.destPort = destPort;
            data.seqNum = nextPacket;
            data.info = instruction;
            data.username = user;
            
            data.message = message;
            data_address = &data;

            
            makePack(&sendPackage, TOS_NODE_ID, dest_addr, MAX_TTL, PROTOCOL_TCP, seqNum, (uint8_t *) data_address, PACKET_MAX_PAYLOAD_SIZE);
            
            sockets[srcPort].effectiveWindow--;
            
            call TCP_Timer.startOneShot(sockets[srcPort].RTT * 2);
            call Sender.send(sendPackage, nexHop);
         }
         else{
            nextPacket++;
            data.srcPort = srcPort;
            data.destPort = destPort;
            data.seqNum = nextPacket;
            data.info = 0;
            data.username = user;
            data.message = "test";
            data_address = &data;
            
            makePack(&sendPackage, TOS_NODE_ID, dest_addr, MAX_TTL, PROTOCOL_TCP, seqNum, (uint8_t *) data_address, PACKET_MAX_PAYLOAD_SIZE);
          
            sockets[srcPort].effectiveWindow--;
            call TCP_Timer.startOneShot(sockets[srcPort].RTT * 2);
            call Sender.send(sendPackage, nexHop);
         }
   }

   uint16_t get_next_hop(uint16_t dest_addr){
      uint8_t i = 0;
      RouteNode r;
      for (i = 0; i < call RouteTable.size(); i++){
         r = call RouteTable.get(i);
         if((dest_addr == (uint16_t) r.dest) && r.cost < 255){
            dbg(ROUTING_CHANNEL, "next hop: %d\n", r.nextHop);
            return r.nextHop;
         }
      }
      return -1;
   }
}
