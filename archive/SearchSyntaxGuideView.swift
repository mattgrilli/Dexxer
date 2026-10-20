//
//  SearchSyntaxGuideView.swift
//  Dexxer
//
//  A view showing search syntax help and examples
//

import SwiftUI

struct SearchSyntaxGuideView: View {
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    
                    // Header
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Search Syntax Guide")
                            .font(.largeTitle)
                            .fontWeight(.bold)
                        
                        Text("Use advanced search syntax to quickly find exactly what you're looking for")
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.bottom, 8)
                    
                    Divider()
                    
                    // Basic Search
                    SyntaxSection(
                        title: "Basic Search",
                        icon: "magnifyingglass",
                        examples: [
                            SearchExample(
                                query: "contract",
                                description: "Find files with 'contract' in name"
                            ),
                            SearchExample(
                                query: "\"annual report\"",
                                description: "Search for exact phrase"
                            ),
                        ]
                    )
                    
                    // File Type
                    SyntaxSection(
                        title: "File Type",
                        icon: "doc.fill",
                        examples: [
                            SearchExample(
                                query: "type:pdf",
                                description: "Find all PDF files"
                            ),
                            SearchExample(
                                query: "ext:docx contract",
                                description: "Word documents with 'contract'"
                            ),
                        ]
                    )
                    
                    // File Size
                    SyntaxSection(
                        title: "File Size",
                        icon: "doc.badge.arrow.up.fill",
                        examples: [
                            SearchExample(
                                query: "size:>10MB",
                                description: "Files larger than 10MB"
                            ),
                            SearchExample(
                                query: "size:<1GB",
                                description: "Files smaller than 1GB"
                            ),
                            SearchExample(
                                query: "size:5MB-50MB",
                                description: "Files between 5-50MB"
                            ),
                        ]
                    )
                    
                    // Modified Date
                    SyntaxSection(
                        title: "Modified Date",
                        icon: "calendar",
                        examples: [
                            SearchExample(
                                query: "modified:today",
                                description: "Files modified today"
                            ),
                            SearchExample(
                                query: "modified:7d",
                                description: "Modified in last 7 days"
                            ),
                            SearchExample(
                                query: "modified:>2024-01-01",
                                description: "Modified after Jan 1, 2024"
                            ),
                            SearchExample(
                                query: "modified:thismonth",
                                description: "Modified this month"
                            ),
                        ]
                    )
                    
                    // Path Filter
                    SyntaxSection(
                        title: "Path Filter",
                        icon: "folder.fill",
                        examples: [
                            SearchExample(
                                query: "path:Legal",
                                description: "Files with 'Legal' in path"
                            ),
                            SearchExample(
                                query: "folder:Documents",
                                description: "Files in Documents folder"
                            ),
                        ]
                    )
                    
                    // Combined Examples
                    SyntaxSection(
                        title: "Combine Filters",
                        icon: "sparkles",
                        examples: [
                            SearchExample(
                                query: "type:pdf size:>5MB modified:today",
                                description: "Large PDFs modified today"
                            ),
                            SearchExample(
                                query: "\"quarterly report\" ext:docx modified:thismonth path:Finance",
                                description: "Recent quarterly reports in Finance folder"
                            ),
                            SearchExample(
                                query: "invoice type:pdf size:>1MB modified:7d",
                                description: "Large PDF invoices from last week"
                            ),
                        ]
                    )
                    
                    Divider()
                    
                    // Tips
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Tips", systemImage: "lightbulb.fill")
                            .font(.headline)
                            .foregroundStyle(.yellow)
                        
                        VStack(alignment: .leading, spacing: 8) {
                            TipRow(text: "Combine multiple filters for powerful searches")
                            TipRow(text: "Use quotes for exact phrase matching")
                            TipRow(text: "Size units: B, KB, MB, GB, TB")
                            TipRow(text: "Date shortcuts: today, yesterday, thisweek, thismonth, 7d, 30d")
                            TipRow(text: "Filters are case-insensitive")
                        }
                    }
                    .padding()
                    .background(Color.yellow.opacity(0.1))
                    .cornerRadius(12)
                }
                .padding()
            }
            .navigationTitle("Search Help")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - Supporting Views

struct SyntaxSection: View {
    let title: String
    let icon: String
    let examples: [SearchExample]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon)
                .font(.headline)
                .foregroundStyle(.primary)
            
            VStack(alignment: .leading, spacing: 8) {
                ForEach(examples) { example in
                    ExampleRow(example: example)
                }
            }
        }
    }
}

struct ExampleRow: View {
    let example: SearchExample
    @State private var copied = false
    
    var body: some View {
        Button {
            #if os(macOS)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(example.query, forType: .string)
            #else
            UIPasteboard.general.string = example.query
            #endif
            
            copied = true
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                copied = false
            }
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(example.query)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.primary)
                    
                    Text(example.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .foregroundStyle(copied ? .green : .secondary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }
}

struct TipRow: View {
    let text: String
    
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "arrow.right.circle.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
            
            Text(text)
                .font(.callout)
        }
    }
}

struct SearchExample: Identifiable {
    let id = UUID()
    let query: String
    let description: String
}

// MARK: - Preview

#Preview {
    SearchSyntaxGuideView()
}

// MARK: - Helper Button for showing the guide

struct SearchHelpButton: View {
    @State private var showingGuide = false
    
    var body: some View {
        Button {
            showingGuide = true
        } label: {
            Label("Search Help", systemImage: "questionmark.circle")
        }
        .sheet(isPresented: $showingGuide) {
            SearchSyntaxGuideView()
        }
    }
}
