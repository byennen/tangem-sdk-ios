////
////  ReadIssuerExtraDataCommand.swift
////  TangemSdk
////
////  Created by Alexander Osokin on 26.02.2020.
////  Copyright © 2020 Tangem AG. All rights reserved.
////
//
//import Foundation
//
///// This enum specifies modes for `ReadIssuerExtraDataCommand` and  `WriteIssuerExtraDataCommand`.
public enum IssuerExtraDataMode: Byte {
    ///This mode is required to read issuer extra data from the card. This mode is required to initiate writing issuer extra data to the card.
    case readOrStartWrite = 1
    
    /// With this mode, the command writes part of issuer extra data
    /// (block of a size [WriteIssuerExtraDataCommand.SINGLE_WRITE_SIZE]) to the card.
    case writePart = 2
    
    /**
     * This mode is used after the issuer extra data was fully written to the card.
     * Under this mode the command provides the issuer signature
     * to confirm the validity of data that was written to card.
     */
    case finalizeWrite = 3
}

public struct ReadIssuerExtraDataResponse: TlvCodable {
    /// Unique Tangem card ID number
    public let cardId: String
    /// Size of all Issuer_Extra_Data field.
    public var size: Int?
    /// Data defined by issuer.
    public var issuerData: Data
    
    /**
     * Issuer’s signature of [issuerData] with Issuer Data Private Key (which is kept on card).
     * Issuer’s signature of SHA256-hashed [cardId] concatenated with [issuerData]:
     * SHA256([cardId] | [issuerData]).
     * When flag [SettingsMask.protectIssuerDataAgainstReplay] set in [SettingsMask] then signature of
     * SHA256-hashed CID Issuer_Data concatenated with and [issuerDataCounter]:
     * SHA256([cardId] | [issuerData] | [issuerDataCounter]).
     */
    public var issuerDataSignature: Data?
    
    /**
     * An optional counter that protect issuer data against replay attack.
     * When flag [SettingsMask.protectIssuerDataAgainstReplay] set in [SettingsMask]
     * then this value is mandatory and must increase on each execution of [WriteIssuerDataCommand].
     */
    public var issuerDataCounter: Int?
    
    public init(cardId: String, size: Int?, issuerData: Data, issuerDataSignature: Data?, issuerDataCounter: Int?) {
        self.cardId = cardId
        self.size = size
        self.issuerData = issuerData
        self.issuerDataSignature = issuerDataSignature
        self.issuerDataCounter = issuerDataCounter
    }
    
    public func verify(with publicKey: Data) -> Bool? {
        guard let signature = issuerDataSignature else {
            return nil
        }
        
        return IssuerDataVerifier.verify(cardId: cardId,
                                         issuerData: issuerData,
                                         issuerDataCounter: issuerDataCounter,
                                         publicKey: publicKey,
                                         signature: signature)
    }
}

/**
 * This command retrieves Issuer Extra Data field and its issuer’s signature.
 * Issuer Extra Data is never changed or parsed from within the Tangem COS. The issuer defines purpose of use,
 * format and payload of Issuer Data. . For example, this field may contain photo or
 * biometric information for ID card product.
 */
@available(iOS 13.0, *)
public final class ReadIssuerExtraDataCommand: Command {
    public typealias CommandResponse = ReadIssuerExtraDataResponse
    
    private var issuerPublicKey: Data?
    private var completion: CompletionResult<ReadIssuerExtraDataResponse>?
    private var viewDelegate: SessionViewDelegate?
    private var issuerData = Data()
    private var issuerDataSize = 0
    
    public init(issuerPublicKey: Data? = nil) {
        self.issuerPublicKey = issuerPublicKey
    }
    
    deinit {
        print("ReadIssuerExtraDataCommand deinit")
    }
    
    public func run(in session: CardSession, completion: @escaping CompletionResult<ReadIssuerExtraDataResponse>) {
        if issuerPublicKey == nil {
            issuerPublicKey = session.environment.card?.issuerPublicKey
        }
        
        guard issuerPublicKey != nil else {
            completion(.failure(.missingIssuerPublicKey))
            return
        }
        
        self.completion = completion
        self.viewDelegate = session.viewDelegate
        readData(session)
    }
    
    private func readData(_ session: CardSession) {
        showProgress()
        transieve(in: session) { result in
            switch result {
            case .success(let response):
                if let dataSize = response.size {
                    if dataSize == 0 { //no data
                        self.completion?(.success(response))
                        return
                    } else {
                        self.issuerDataSize = dataSize // initialize only at start
                    }
                }
                
                self.issuerData.append(response.issuerData)
                
                if response.issuerDataSignature == nil {
                    self.readData(session)
                } else {
                    self.showProgress()
                    let finalResponse = ReadIssuerExtraDataResponse(cardId: response.cardId,
                                                                    size: response.size,
                                                                    issuerData: self.issuerData,
                                                                    issuerDataSignature: response.issuerDataSignature,
                                                                    issuerDataCounter: response.issuerDataCounter)
                    
                    if let result = finalResponse.verify(with: self.issuerPublicKey!),
                        result == true {
                        self.completion?(.success(finalResponse))
                    } else {
                        self.completion?(.failure(.verificationFailed))
                    }
                }
            case .failure(let error):
                self.completion?(.failure(error))
            }
        }
    }
    
    private func showProgress() {
        if issuerDataSize == 0 {
            return
        }
        let progress = Int(round(Float(issuerData.count)/Float(issuerDataSize) * 100.0))
        viewDelegate?.showAlertMessage(Localization.readProgress(progress.description))
    }
    
    public func serialize(with environment: SessionEnvironment) throws -> CommandApdu {
        let tlvBuilder = try createTlvBuilder(legacyMode: environment.legacyMode)
            .append(.pin, value: environment.pin1)
            .append(.cardId, value: environment.card?.cardId)
            .append(.mode, value: IssuerExtraDataMode.readOrStartWrite)
            .append(.offset, value: issuerData.count)
        
        return CommandApdu(.readIssuerData, tlv: tlvBuilder.serialize())
    }
    
    public func deserialize(with environment: SessionEnvironment, from apdu: ResponseApdu) throws -> ReadIssuerExtraDataResponse {
        guard let tlv = apdu.getTlvData(encryptionKey: environment.encryptionKey) else {
            throw SessionError.deserializeApduFailed
        }
        
        let decoder = TlvDecoder(tlv: tlv)
        return ReadIssuerExtraDataResponse(
            cardId: try decoder.decode(.cardId),
            size: try decoder.decodeOptional(.size),
            issuerData: try decoder.decodeOptional(.issuerData) ?? Data(),
            issuerDataSignature: try decoder.decodeOptional(.issuerDataSignature),
            issuerDataCounter: try decoder.decodeOptional(.issuerDataCounter))
    }
}
