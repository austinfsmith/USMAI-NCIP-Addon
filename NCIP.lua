-- ILLiad to Aleph NCIP Messaging addon
--
-- Austin Smith, University of Maryland College Park. afsmith@umd.edu
-- System Addon used for ILLiad to communicate with Aleph through NCIP protocol

require "AtlasHelpers";
luanet.load_assembly("System");

-- Load settings & register for system timer
function Init()
  Settings = {};

  Settings.NCIPResponderURL = GetSetting("NCIPResponderURL");
  Settings.AcceptItemFailQueue = GetSetting("AcceptItemFailQueue");
  Settings.AcceptItemSuccessQueue = GetSetting("AcceptItemSuccessQueue");
  Settings.AlephItemBarcodeField = GetSetting("AlephItemBarcodeField");
  Settings.CreateHoldRequest = GetSetting("CreateHoldRequest");
  Settings.ProcessLibraryUseOnly = GetSetting("ProcessLibraryUseOnly");
  Settings.ILLiadLocationTable = GetSetting("ILLiadLocationTable");
  Settings.ILLiadLocationField = GetSetting("ILLiadLocationField");
  Settings.UseItemBarcodePrefixes = GetSetting("UseItemBarcodePrefixes");
  -- tables to store parameters for shared server / multiple location support
  Settings.ILLiadLocationCodes = {};
  Settings.AlephLocationCodes = {};
  Settings.UserPrefixes = {};
  Settings.Sublibraries = {};
  Settings.ItemBarcodePrefixes = {};

  -- parse comma-separated setting strings into tables
  GetSetting("ILLiadLocationCodes"):gsub("[^,%s]+", function(c) table.insert(Settings.ILLiadLocationCodes,c) end);
  GetSetting("AlephLocationCodes"):gsub("[^,%s]+", function(c) table.insert(Settings.AlephLocationCodes,c) end);
  GetSetting("UserPrefixes"):gsub("[^,%s]+", function(c) table.insert(Settings.UserPrefixes,c) end);
  GetSetting("Sublibraries"):gsub("[^,%s]+", function(c) table.insert(Settings.Sublibraries,c) end);
  GetSetting("ItemBarcodePrefixes"):gsub("[^,%s]+", function(c) table.insert(Settings.ItemBarcodePrefixes,c) end);

  -- build inverse index for ILLiad location codes, for easier lookup
  -- usage: assuming n = the current location code,
  -- aleph location = AlephLocationCodes[ILLiadLocationCodes[n]]
  -- user prefix = UserPrefixes[ILLiadLocationCodes[n]]
  -- sublibrary = Sublibraries[ILLiadLocationCodes[n]]
  for k,v in pairs(Settings.ILLiadLocationCodes) do
    Settings.ILLiadLocationCodes[v]=k
  end

  -- Check the config strings to make sure they all have the same number of elements.
  -- If not, quit without registering event handlers.
  if #Settings.ILLiadLocationCodes ~= #Settings.AlephLocationCodes or
     #Settings.ILLiadLocationCodes ~= #Settings.UserPrefixes or
     #Settings.ILLiadLocationCodes ~= #Settings.Sublibraries  or
     #Settings.ILLiadLocationCodes ~= #Settings.ItemBarcodePrefixes  then
    LogDebug("NCIP Addon Configuration Error: Configuration strings are of different length.")
    return
  else
    -- otherwise, register an event handler.
    RegisterSystemEventHandler("SystemTimerElapsed", "ProcessItems");
    LogDebug("NCIP Addon configured.")
  end
end

-- ProcessDataContexts takes a column, a value, and a function,
-- and calls the function for each row with the given value in the given column.
-- "In Transit to Pickup Location" is a transitory queue in ILLiad which serves
-- much the same purpose as "In Transit"/"In Process" in Aleph, so it's a good
-- point in the ILL process to identify items that may need to be loaded into Aleph.
function ProcessItems()
  ProcessDataContexts("transactionstatus","In Transit to Pickup Location","BorrowingAcceptItem");
end

-- Sends a message and returns a response.
-- Broken out into a separate function because this makes ILLiad's error logging
-- more informative, and so the code can be reused when we develop additional
-- uses for the protocol.
-- @param m: the message to send
-- @return: the response received.
function SendNCIPMessage(m)
  LogDebug("Sending message:\n" .. m);
  local NCIP_message = AtlasHelpers.UrlEncode(m);
  local WebClient = luanet.import_type("System.Net.WebClient");
  local myWebClient = WebClient();
  myWebClient.Headers:Add("Content-Type", "text/html; charset=UTF-8");
  local NCIP_response = myWebClient:UploadString(Settings.NCIPResponderURL, NCIP_message);
  LogDebug("Response was:\n" .. NCIP_response);
  return NCIP_response;
end

-- Strip out any characters that may cause problems in an XML message.
-- This is needed because we don't have proper XML handling in Lua, so
-- all messages are built usin string formatting.
-- @param str: the string to process.
-- @return: the string, post-processing.
function CleanString(str)
  str = string.gsub(str, "&","and");
  str = string.gsub(str, "<","");
  str = string.gsub(str, ">","");
  --str = string.gsub("'","");
  --str = string.gsub('"',"");
  return str
end

-- Send an Accept Item message to the NCIP Responder.
-- This will be called within a context that allows us to get & set fields in the
-- User and Transaction tables for this request, which is convenient.
-- That context evaporates as soon as an error is encountered, which is inconvenient.
-- @param transactionProcessedEventArgs: args supplied by the system event handler (not used)
function BorrowingAcceptItem(transactionProcessedEventArgs)

  LogDebug("NCIP Addon - Borrowing Accept Item - Checking Request.");

  currentTN = GetFieldValue("Transaction","TransactionNumber")

  -- Skip non-loan requests.
	if GetFieldValue("Transaction", "RequestType") ~= "Loan" then
    return
  end
  -- Skip LUO requests, if configured to do so.
  if GetFieldValue("Transaction", "LibraryUseOnly") == true and Settings.ProcessLibraryUseOnly == false then
    ExecuteCommand("Route", {currentTN, "LIBRARY USE ONLY"});
    return
  end

  -- Skip unconfigured sites
  local illiad_location = Settings.ILLiadLocationCodes[GetFieldValue(Settings.ILLiadLocationTable,Settings.ILLiadLocationField)];
  if illiad_location == nil then
    LogDebug("NCIP Addon not configured for this ILLiad location.");
    return
  end

  LogDebug("NCIP Addon - Borrowing Accept Item start");

  -- Get the correct ILLiad location code for this transaction,
  -- then look up the corresponding values for other fields
  local username = Settings.UserPrefixes[illiad_location] .. GetFieldValue("Transaction", "Username");

  local item_barcode = currentTN;
  if (Settings.UseItemBarcodePrefixes == true) then
    item_barcode = Settings.ItemBarcodePrefixes[illiad_location] .. currentTN;
  end

  local sublibrary = Settings.Sublibraries[illiad_location];

  if (Settings.CreateHoldRequest == true) then
    aleph_location = Settings.AlephLocationCodes[illiad_location];
  else
    aleph_location = "NONE";
  end

  local author = CleanString(GetFieldValue("Transaction", "LoanAuthor")) or " ";
  local title = CleanString(GetFieldValue("Transaction", "LoanTitle")) or " ";

  accept_item_message = [[
    <NCIPMessage version="http://www.niso.org/ncip/v1_0/imp1/dtd/ncip_v1_0.dtd">
  	 <AcceptItem>
  	  <InitiationHeader>
  	   <FromAgencyId>
  	    <UniqueAgencyId>
  	     <Scheme></Scheme>
  	     <Value>%s</Value>
  	    </UniqueAgencyId>
  	   </FromAgencyId>
  	   <ToAgencyId>
  	    <UniqueAgencyId>
  	     <Scheme></Scheme>
  	     <Value>%s</Value>
  	    </UniqueAgencyId>
  	   </ToAgencyId>
  	  </InitiationHeader>
  	  <UniqueRequestId>
  	   <RequestIdentifierValue>%s</RequestIdentifierValue>
  	  </UniqueRequestId>
  	  <RequestedActionType>
  	   <Scheme>http://www.niso.org/ncip/v1_0/imp1/schemes/requestedactiontype/requestedactiontype.scm</Scheme>
  	   <Value>Hold for Pickup</Value>
  	  </RequestedActionType>
  	  <UniqueUserId>
  	   <UserIdentifierValue>%s</UserIdentifierValue>
  	  </UniqueUserId>
  	  <UniqueItemId>
  	   <ItemIdentifierValue>%s</ItemIdentifierValue>
  	  </UniqueItemId>
  	  <ItemOptionalFields>
  	   <BibliographicDescription>
  	   <Author>%s</Author>
  	   <Title>%s</Title>
  	   </BibliographicDescription>
  	  </ItemOptionalFields>
  	 </AcceptItem>
    </NCIPMessage>]]

  -- Merge values into NCIP message
  local message = string.format(accept_item_message, sublibrary, aleph_location, item_barcode, username, item_barcode, author, title);
  response = SendNCIPMessage(message);

  -- Check for errors in the most primitive way imaginable.
	if string.find(response, "<Problem>") then
    if string.find(response, "<Value>Duplicate Item</Value>") then
      LogDebug("NCIP Error: Duplicate Item. Routing to success queue.")
      ExecuteCommand("AddNote", {currentTN, "Duplicate record not created for TN" .. currentTN});
      ExecuteCommand("Route", {currentTN, Settings.AcceptItemSuccessQueue});
      SaveDataSource("Transaction")
    else
      LogDebug("NCIP Error: Re-Routing Transaction");
      ExecuteCommand("Route", {currentTN, Settings.AcceptItemFailQueue});
      LogDebug("Adding Note to Transaction with NCIP Client Error");
      ExecuteCommand("AddNote", {currentTN, response});
      SaveDataSource("Transaction");
      return;
    end
  else
	  LogDebug("No Problems found in NCIP Response.");
	  ExecuteCommand("AddNote", {currentTN, "NCIP Addon: Aleph record successfully created with barcode " .. item_barcode});
    if Settings.AlephItemBarcodeField and Settings.AlephItemBarcodeField ~= "" then
      LogDebug("NCIP Addon Saving item barcode: "..item_barcode)
      SetFieldValue("Transaction", Settings.AlephItemBarcodeField, item_barcode)
    end
    LogDebug("NCIP Addon Routing item to "..Settings.AcceptItemSuccessQueue)
    ExecuteCommand("Route", {currentTN, Settings.AcceptItemSuccessQueue});
    SaveDataSource("Transaction");
  end
end

-- There's no real way for us to recover from errors, as they'll mostly result
-- from configuration problems. We'll just add a note to the affected request,
-- and route it to the error queue.

function OnError(e)
  LogDebug("NCIP Addon - Error processing item "..str(currentTN))
  ExecuteCommand("AddNote", {currentTN, "NCIP Addon: Unable to process this request. Please check your addon configuration. Error message: "..e.Message});
  ExecuteCommand("Route", {currentTN, Settings.AcceptItemFailQueue});
end
